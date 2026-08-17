using Flux
using FileIO
using Random
using Serialization

struct SymbolImageDataset
    images::Array{Float32,4}
    labels::Vector{Int}
    label_names::Vector{String}
    paths::Vector{String}
    image_size::Tuple{Int,Int}
end

struct SymbolSourceDataset
    masks::Vector{BitMatrix}
    labels::Vector{Int}
    label_names::Vector{String}
    paths::Vector{String}
    image_size::Tuple{Int,Int}
end

struct SymbolClassifier
    body
    embedding
    head
    label_names::Vector{String}
    image_size::Tuple{Int,Int}
end

Flux.@layer SymbolClassifier trainable=(body, embedding, head)

function (classifier::SymbolClassifier)(images)
    return classifier.head(symbol_embeddings(classifier, images))
end

struct SymbolTrainingResult
    classifier::SymbolClassifier
    train_dataset
    test_dataset
    train_metrics::Vector{Dict{String,Any}}
    test_metrics::Vector{Dict{String,Any}}
end

"""
    load_symbol_dataset(dataset_dir; split="train", label_names=nothing, image_size=nothing)

Load a generated dataset split from `dataset_dir/train/<label>` or
`dataset_dir/test/<label>`.
"""
function load_symbol_dataset(
    dataset_dir::AbstractString;
    split::AbstractString="train",
    label_names::Union{Nothing,Vector{String}}=nothing,
    image_size::Union{Nothing,Tuple{Int,Int}}=nothing,
)
    split_dir = joinpath(dataset_dir, split)
    isdir(split_dir) || throw(ArgumentError("dataset split directory does not exist: $(split_dir)"))

    discovered_labels = sorted_subdirectories(split_dir)
    labels = isnothing(label_names) ? discovered_labels : label_names
    isempty(labels) && throw(ArgumentError("no label directories found in $(split_dir)"))

    paths = String[]
    label_indices = Int[]

    for (label_index, label) in enumerate(labels)
        label_dir = joinpath(split_dir, label)
        isdir(label_dir) || continue

        for path in sorted_png_files(label_dir)
            is_pending_path(path) && throw(ArgumentError("pending image cannot be used for training: $(path)"))
            push!(paths, path)
            push!(label_indices, label_index)
        end
    end

    isempty(paths) && throw(ArgumentError("no PNG images found in $(split_dir)"))

    first_image = load_symbol_image(paths[1])
    target_size = isnothing(image_size) ? size(first_image) : image_size
    images = Array{Float32,4}(undef, target_size[1], target_size[2], 1, length(paths))

    for (index, path) in enumerate(paths)
        is_pending_path(path) && throw(ArgumentError("pending image cannot be used for training: $(path)"))
        image = load_symbol_image(path)
        if size(image) != target_size
            image = nearest_resize(image, target_size)
        end
        images[:, :, 1, index] .= Float32.(image)
    end

    return SymbolImageDataset(images, label_indices, copy(labels), paths, target_size)
end

"""
    load_symbol_source_datasets(labeling_output_dir; train_percent=0.8, image_size=nothing)

Load clean labeled source tiles from a previous labeling output directory and
split them by source tile into train/test datasets. These datasets are intended
for on-demand augmentation during training.
"""
function load_symbol_source_datasets(
    labeling_output_dir::AbstractString;
    train_percent::Real=0.8,
    image_size::Union{Nothing,Tuple{Int,Int}}=nothing,
    rng::AbstractRNG=Random.default_rng(),
)
    grouped_paths, _ = group_tile_paths_by_label_dir(labeling_output_dir)
    isempty(grouped_paths) && throw(ArgumentError("No labeled PNG files found in labeling_output_dir"))

    label_names = sort(collect(keys(grouped_paths)))
    train_masks = BitMatrix[]
    train_labels = Int[]
    train_paths = String[]
    test_masks = BitMatrix[]
    test_labels = Int[]
    test_paths = String[]
    target_size = image_size
    train_fraction = clamp(normalize_percent(train_percent), 0.0, 1.0)

    for (label_index, label) in enumerate(label_names)
        paths = shuffle(rng, grouped_paths[label])
        train_count = train_source_count(length(paths), train_fraction)

        for (path_index, path) in enumerate(paths)
            is_pending_path(path) && throw(ArgumentError("pending image cannot be used for training: $(path)"))
            mask = load_symbol_source_mask(path)
            if isnothing(target_size)
                target_size = size(mask)
            elseif size(mask) != target_size
                mask = nearest_resize(mask, target_size) .> 0
            end

            if path_index <= train_count
                push!(train_masks, BitMatrix(mask))
                push!(train_labels, label_index)
                push!(train_paths, path)
            else
                push!(test_masks, BitMatrix(mask))
                push!(test_labels, label_index)
                push!(test_paths, path)
            end
        end
    end

    isnothing(target_size) && throw(ArgumentError("no source masks could be loaded"))
    train_dataset = SymbolSourceDataset(train_masks, train_labels, label_names, train_paths, target_size)
    test_dataset = isempty(test_masks) ? nothing : SymbolSourceDataset(test_masks, test_labels, label_names, test_paths, target_size)

    return train_dataset, test_dataset
end

function load_symbol_source_mask(path::AbstractString)
    is_pending_path(path) && throw(ArgumentError("pending image cannot be used for training: $(path)"))
    mask = bitmap_black_mask(load(path))
    if isnothing(mask)
        gray = load_symbol_image(path)
        return gray .< 0.5
    end

    return mask
end

function sorted_subdirectories(dir::AbstractString)
    names = filter(name -> isdir(joinpath(dir, name)), readdir(dir))
    return sort(names)
end

function sorted_png_files(dir::AbstractString)
    names = filter(name -> lowercase(splitext(name)[2]) == ".png", readdir(dir))
    return [joinpath(dir, name) for name in sort(names)]
end

function load_symbol_image(path::AbstractString)
    is_pending_path(path) && throw(ArgumentError("pending image cannot be used for training: $(path)"))
    gray = grayscale_float_image(load(path))
    return Float32.(gray)
end

function nearest_resize(image, target_size::Tuple{Int,Int})
    target_height, target_width = target_size
    source_height, source_width = size(image)
    resized = Array{eltype(image)}(undef, target_height, target_width)

    for row in 1:target_height
        source_row = clamp(round(Int, (row - 0.5) * source_height / target_height + 0.5), 1, source_height)
        for col in 1:target_width
            source_col = clamp(round(Int, (col - 0.5) * source_width / target_width + 0.5), 1, source_width)
            resized[row, col] = image[source_row, source_col]
        end
    end

    return resized
end

"""
    create_symbol_classifier(image_size, label_names; embedding_dim=64)

Create a small CNN classifier with an explicit embedding layer before the final
classification head.
"""
function create_symbol_classifier(
    image_size::Tuple{Int,Int},
    label_names::Vector{String};
    embedding_dim::Integer=64,
)
    body = Chain(
        Conv((3, 3), 1 => 16, relu; pad=1),
        MaxPool((2, 2)),
        Conv((3, 3), 16 => 32, relu; pad=1),
        MaxPool((2, 2)),
        Conv((3, 3), 32 => 64, relu; pad=1),
    )
    dummy = zeros(Float32, image_size[1], image_size[2], 1, 1)
    flattened_dim = size(flatten_batch(body(dummy)), 1)
    embedding = Chain(Dense(flattened_dim => embedding_dim, relu))
    head = Dense(embedding_dim => length(label_names))

    return SymbolClassifier(body, embedding, head, copy(label_names), image_size)
end

function flatten_batch(x)
    return reshape(x, :, size(x, 4))
end

function symbol_embeddings(classifier::SymbolClassifier, images)
    return classifier.embedding(flatten_batch(classifier.body(images)))
end

"""
    train_symbol_classifier(dataset_dir; kwargs...)

Train a small CNN classifier using `dataset_dir/train/<label>` and, if present,
evaluate on `dataset_dir/test/<label>`.
"""
function train_symbol_classifier(
    dataset_dir::AbstractString;
    image_size::Union{Nothing,Tuple{Int,Int}}=nothing,
    embedding_dim::Integer=64,
    batch_size::Integer=32,
    epochs::Integer=10,
    learning_rate::Real=1f-3,
    rng::AbstractRNG=Random.default_rng(),
    verbose::Bool=true,
)
    train_dataset = load_symbol_dataset(dataset_dir; split="train", image_size)
    test_dataset = isdir(joinpath(dataset_dir, "test")) ?
        load_symbol_dataset(
            dataset_dir;
            split="test",
            label_names=train_dataset.label_names,
            image_size=train_dataset.image_size,
        ) :
        nothing

    classifier = create_symbol_classifier(
        train_dataset.image_size,
        train_dataset.label_names;
        embedding_dim,
    )
    opt_state = Flux.setup(Flux.Adam(Float32(learning_rate)), classifier)
    train_metrics = Dict{String,Any}[]
    test_metrics = Dict{String,Any}[]

    for epoch in 1:epochs
        for batch_indices in minibatches(length(train_dataset.labels), batch_size, rng)
            x = train_dataset.images[:, :, :, batch_indices]
            y = Flux.onehotbatch(train_dataset.labels[batch_indices], 1:length(train_dataset.label_names))

            loss, grads = Flux.withgradient(classifier) do model
                Flux.logitcrossentropy(model(x), y)
            end
            Flux.update!(opt_state, classifier, grads[1])
        end

        train_metric = evaluate_symbol_classifier(classifier, train_dataset)
        push!(train_metrics, train_metric)

        if !isnothing(test_dataset)
            test_metric = evaluate_symbol_classifier(classifier, test_dataset)
            push!(test_metrics, test_metric)
        end

        if verbose
            if isnothing(test_dataset)
                println("epoch=", epoch, " train_accuracy=", round(train_metric["accuracy"]; digits=4))
            else
                println(
                    "epoch=", epoch,
                    " train_accuracy=", round(train_metric["accuracy"]; digits=4),
                    " test_accuracy=", round(test_metrics[end]["accuracy"]; digits=4),
                )
            end
        end
    end

    return SymbolTrainingResult(classifier, train_dataset, test_dataset, train_metrics, test_metrics)
end

"""
    train_symbol_classifier_on_demand(labeling_output_dir; kwargs...)

Train a small CNN classifier from clean labeled source tiles while generating
fresh augmentations during training. This avoids writing a large augmented
dataset to disk.

Model/training kwargs include `epochs`, `batch_size`, `embedding_dim`,
`learning_rate`, `train_percent`, and `samples_per_source_per_epoch`.
Additional keyword arguments are forwarded to `augment_image`.
"""
function train_symbol_classifier_on_demand(
    labeling_output_dir::AbstractString;
    image_size::Union{Nothing,Tuple{Int,Int}}=nothing,
    embedding_dim::Integer=64,
    batch_size::Integer=32,
    epochs::Integer=10,
    learning_rate::Real=1f-3,
    train_percent::Real=0.8,
    samples_per_source_per_epoch::Integer=1,
    eval_augmentations_per_source::Integer=4,
    rng::AbstractRNG=Random.default_rng(),
    verbose::Bool=true,
    kwargs...,
)
    samples_per_source_per_epoch > 0 || throw(ArgumentError("samples_per_source_per_epoch must be positive"))
    eval_augmentations_per_source > 0 || throw(ArgumentError("eval_augmentations_per_source must be positive"))
    train_dataset, test_dataset = load_symbol_source_datasets(
        labeling_output_dir;
        train_percent,
        image_size,
        rng,
    )

    classifier = create_symbol_classifier(
        train_dataset.image_size,
        train_dataset.label_names;
        embedding_dim,
    )
    opt_state = Flux.setup(Flux.Adam(Float32(learning_rate)), classifier)
    train_metrics = Dict{String,Any}[]
    test_metrics = Dict{String,Any}[]

    for epoch in 1:epochs
        epoch_indices = repeat(collect(eachindex(train_dataset.labels)); inner=samples_per_source_per_epoch)
        shuffle!(rng, epoch_indices)

        for batch_indices in minibatches(epoch_indices, batch_size)
            x = augmented_source_batch(train_dataset, batch_indices; rng, kwargs...)
            y = Flux.onehotbatch(train_dataset.labels[batch_indices], 1:length(train_dataset.label_names))

            loss, grads = Flux.withgradient(classifier) do model
                Flux.logitcrossentropy(model(x), y)
            end
            Flux.update!(opt_state, classifier, grads[1])
        end

        train_metric = evaluate_symbol_classifier(
            classifier,
            train_dataset;
            augmentations_per_source=eval_augmentations_per_source,
            rng,
            kwargs...,
        )
        push!(train_metrics, train_metric)

        if !isnothing(test_dataset)
            test_metric = evaluate_symbol_classifier(
                classifier,
                test_dataset;
                augmentations_per_source=eval_augmentations_per_source,
                rng,
                kwargs...,
            )
            push!(test_metrics, test_metric)
        end

        if verbose
            if isnothing(test_dataset)
                println("epoch=", epoch, " train_accuracy=", round(train_metric["accuracy"]; digits=4))
            else
                println(
                    "epoch=", epoch,
                    " train_accuracy=", round(train_metric["accuracy"]; digits=4),
                    " test_accuracy=", round(test_metrics[end]["accuracy"]; digits=4),
                )
            end
        end
    end

    return SymbolTrainingResult(classifier, train_dataset, test_dataset, train_metrics, test_metrics)
end

function minibatches(n::Integer, batch_size::Integer, rng::AbstractRNG)
    batch_size > 0 || throw(ArgumentError("batch_size must be positive"))
    indices = shuffle(rng, collect(1:n))
    return [indices[start:min(start + batch_size - 1, n)] for start in 1:batch_size:n]
end

function minibatches(indices::Vector{Int}, batch_size::Integer)
    batch_size > 0 || throw(ArgumentError("batch_size must be positive"))
    return [indices[start:min(start + batch_size - 1, length(indices))] for start in 1:batch_size:length(indices)]
end

function augmented_source_batch(
    dataset::SymbolSourceDataset,
    batch_indices;
    rng::AbstractRNG,
    kwargs...,
)
    height, width = dataset.image_size
    images = Array{Float32,4}(undef, height, width, 1, length(batch_indices))

    for (batch_position, source_index) in enumerate(batch_indices)
        augmented = augment_black_mask(dataset.masks[source_index]; rng, kwargs...)
        images[:, :, 1, batch_position] .= Float32.(grayscale_float_image(augmented))
    end

    return images
end

function clean_source_images(dataset::SymbolSourceDataset)
    height, width = dataset.image_size
    images = Array{Float32,4}(undef, height, width, 1, length(dataset.labels))

    for (index, mask) in enumerate(dataset.masks)
        images[:, :, 1, index] .= ifelse.(mask, 0.0f0, 1.0f0)
    end

    return images
end

function evaluate_symbol_classifier(classifier::SymbolClassifier, dataset::SymbolImageDataset; kwargs...)
    logits = classifier(dataset.images)
    predictions = class_indices(logits)
    loss = Flux.logitcrossentropy(
        logits,
        Flux.onehotbatch(dataset.labels, 1:length(dataset.label_names)),
    )

    return classification_metrics(
        predictions,
        dataset.labels,
        dataset.label_names;
        loss=Float64(loss),
        samples_per_source=1,
    )
end

function evaluate_symbol_classifier(
    classifier::SymbolClassifier,
    dataset::SymbolSourceDataset;
    augmentations_per_source::Integer=4,
    rng::AbstractRNG=Random.default_rng(),
    kwargs...,
)
    augmentations_per_source > 0 || throw(ArgumentError("augmentations_per_source must be positive"))
    indices = repeat(collect(eachindex(dataset.labels)); inner=augmentations_per_source)
    images = augmented_source_batch(dataset, indices; rng, kwargs...)
    labels = dataset.labels[indices]
    logits = classifier(images)
    predictions = class_indices(logits)
    loss = Flux.logitcrossentropy(
        logits,
        Flux.onehotbatch(labels, 1:length(dataset.label_names)),
    )

    return classification_metrics(
        predictions,
        labels,
        dataset.label_names;
        loss=Float64(loss),
        samples_per_source=augmentations_per_source,
    )
end

function class_indices(logits)
    scores = Array(logits)
    return [findmax(view(scores, :, index))[2] for index in axes(scores, 2)]
end

function classification_metrics(
    predictions,
    labels,
    label_names;
    loss::Real,
    samples_per_source::Integer,
)
    correct = count(==(true), predictions .== labels)
    total = length(labels)
    matrix = confusion_matrix(predictions, labels, length(label_names))

    return Dict{String,Any}(
        "accuracy" => total == 0 ? 0.0 : correct / total,
        "loss" => Float64(loss),
        "correct" => correct,
        "total" => total,
        "samples_per_source" => samples_per_source,
        "confusion_matrix" => matrix,
        "label_names" => copy(label_names),
    )
end

function confusion_matrix(predictions, labels, nlabels::Integer)
    matrix = zeros(Int, nlabels, nlabels)
    for (actual, predicted) in zip(labels, predictions)
        matrix[actual, predicted] += 1
    end
    return matrix
end

function print_confusion_matrix(metrics::AbstractDict)
    labels = metrics["label_names"]
    matrix = metrics["confusion_matrix"]
    println("Confusion matrix: rows=actual, columns=predicted")
    print(rpad("", 14))
    for label in labels
        print(rpad(label, 10))
    end
    println()

    for (index, label) in enumerate(labels)
        print(rpad(label, 14))
        for value in matrix[index, :]
            print(rpad(string(value), 10))
        end
        println()
    end
end

"""
    save_symbol_classifier(classifier, path)

Save a trained `SymbolClassifier` to `path`.

This uses Julia serialization, so it is intended for reloading in the same
project/code environment.
"""
function save_symbol_classifier(classifier::SymbolClassifier, path::AbstractString)
    parent = dirname(path)
    if !isempty(parent)
        mkpath(parent)
    end

    open(path, "w") do io
        serialize(io, classifier)
    end

    return path
end

save_symbol_classifier(training::SymbolTrainingResult, path::AbstractString) =
    save_symbol_classifier(training.classifier, path)

"""
    load_symbol_classifier(path)

Load a `SymbolClassifier` saved by `save_symbol_classifier`.
"""
function load_symbol_classifier(path::AbstractString)
    classifier = open(deserialize, path)
    classifier isa SymbolClassifier || throw(ArgumentError("file does not contain a SymbolClassifier"))
    return classifier
end

"""
    predict_symbol(classifier, image_or_path)

Return `(label, confidence, probabilities)` for one image or image path.
"""
function predict_symbol(classifier::SymbolClassifier, image_or_path)
    image = image_or_path isa AbstractString ? load_symbol_image(image_or_path) : Float32.(grayscale_float_image(image_or_path))
    if size(image) != classifier.image_size
        image = nearest_resize(image, classifier.image_size)
    end

    batch = reshape(image, size(image, 1), size(image, 2), 1, 1)
    probabilities = vec(Flux.softmax(classifier(batch)))
    index = findmax(probabilities)[2]
    return classifier.label_names[index], Float64(probabilities[index]), probabilities
end

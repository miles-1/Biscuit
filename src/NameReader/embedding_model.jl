using Flux
using Hungarian
using LinearAlgebra
using Random
using Serialization
using Statistics

"""
    SymbolEmbeddingModel

Turns a name image into a unit-length fingerprint vector. Unlike
`SymbolClassifier`, this model has no fixed list of labels, so students can be
added or removed by editing a `SymbolGallery` instead of retraining.
"""
struct SymbolEmbeddingModel
    trunk
    projection
    image_size::Tuple{Int,Int}
    embedding_dim::Int
    horizontal_bins::Int
end

Flux.@layer SymbolEmbeddingModel trainable=(trunk, projection)

function (model::SymbolEmbeddingModel)(images)
    return l2_normalize(model.projection(flatten_batch(model.trunk(images))))
end

"""
    CosineMarginHead

Training-only head implementing the additive cosine margin (CosFace/AM-Softmax)
objective. Each column of `weight` is a learned class direction. The margin is
subtracted from the true class score, which forces the model to separate classes
by an angular gap rather than merely getting them on the right side of a
boundary. The head is discarded after training.
"""
struct CosineMarginHead
    weight::Matrix{Float32}
    margin::Float32
    scale::Float32
end

Flux.@layer CosineMarginHead trainable=(weight,)

function (head::CosineMarginHead)(embeddings, onehot_labels)
    cosine = transpose(l2_normalize(head.weight)) * embeddings
    return head.scale .* (cosine .- head.margin .* onehot_labels)
end

"""
    SymbolGallery

The roster: a label for each enrolled student plus their prototype fingerprint.
Prototypes are produced by `model`, so they must be rebuilt whenever the model
is retrained.
"""
mutable struct SymbolGallery
    model::SymbolEmbeddingModel
    label_names::Vector{String}
    prototypes::Matrix{Float32}
end

"""
    SymbolSourceSplit

Two independent splits of the labeled tiles. Labels are divided into those the
model trains on and those held out entirely, and within every label the tiles
are divided into enrollment tiles and query tiles.

Accuracy on `train_query` measures performance on students the model was
trained on. Accuracy on `holdout_query`, using a gallery built from
`holdout_enroll`, measures what actually matters here: identifying a student
whose handwriting the model never saw during training.
"""
struct SymbolSourceSplit
    train::SymbolSourceDataset
    train_query::Union{Nothing,SymbolSourceDataset}
    holdout_enroll::Union{Nothing,SymbolSourceDataset}
    holdout_query::Union{Nothing,SymbolSourceDataset}
    label_names::Vector{String}
    holdout_label_names::Vector{String}
end

struct SymbolEmbeddingResult
    model::SymbolEmbeddingModel
    split::SymbolSourceSplit
    gallery::SymbolGallery
    known_metrics::Vector{Dict{String,Any}}
    holdout_metrics::Vector{Dict{String,Any}}
end

function l2_normalize(x; dims=1)
    return x ./ sqrt.(sum(abs2, x; dims=dims) .+ 1f-10)
end

"""
    resize_source_mask(mask, target_size)

Resize a binary ink mask. Shrinking uses a block-wise OR so that a target pixel
is inked whenever any source pixel in its block was. Plain nearest-neighbour
sampling would drop most of a one-pixel-wide skeleton when downscaling.
"""
function resize_source_mask(mask::AbstractMatrix, target_size::Tuple{Int,Int})
    size(mask) == target_size && return BitMatrix(mask)

    target_height, target_width = target_size
    source_height, source_width = size(mask)
    if target_height >= source_height && target_width >= source_width
        return BitMatrix(nearest_resize(mask, target_size) .> 0)
    end

    row_bounds = block_bounds(source_height, target_height)
    col_bounds = block_bounds(source_width, target_width)
    shrunk = falses(target_height, target_width)

    for row in 1:target_height
        row_range = row_bounds[row]
        for col in 1:target_width
            shrunk[row, col] = any(view(mask, row_range, col_bounds[col]))
        end
    end

    return shrunk
end

function block_bounds(source_length::Integer, target_length::Integer)
    bounds = Vector{UnitRange{Int}}(undef, target_length)

    for index in 1:target_length
        first_position = floor(Int, (index - 1) * source_length / target_length) + 1
        last_position = ceil(Int, index * source_length / target_length)
        last_position = clamp(last_position, first_position, source_length)
        bounds[index] = first_position:last_position
    end

    return bounds
end

"""
    create_symbol_embedder(image_size; embedding_dim=128, horizontal_bins=16)

Build the fingerprint network.

The convolution stack is followed by `AdaptiveMeanPool((1, horizontal_bins))`,
which averages away the vertical axis completely and compresses the horizontal
axis into `horizontal_bins` slices. Flattening the feature map instead would
make the layer that follows it tens of millions of parameters and let the model
memorize the exact pixel position of every stroke. Keeping a coarse horizontal
axis preserves the left-to-right order of the writing, which a single global
average would throw away.

`projection` is deliberately linear: a `relu` here would confine every
fingerprint to the positive orthant and distort the angles that matching relies
on.
"""
function create_symbol_embedder(
    image_size::Tuple{Int,Int};
    embedding_dim::Integer=128,
    horizontal_bins::Integer=16,
)
    horizontal_bins > 0 || throw(ArgumentError("horizontal_bins must be positive"))
    embedding_dim > 0 || throw(ArgumentError("embedding_dim must be positive"))

    trunk = Chain(
        Conv((3, 3), 1 => 16, relu; pad=1),
        MaxPool((2, 2)),
        Conv((3, 3), 16 => 32, relu; pad=1),
        MaxPool((2, 2)),
        Conv((3, 3), 32 => 64, relu; pad=1),
        MaxPool((2, 2)),
        Conv((3, 3), 64 => 128, relu; pad=1),
        AdaptiveMeanPool((1, horizontal_bins)),
    )

    dummy = zeros(Float32, image_size[1], image_size[2], 1, 1)
    feature_width = size(trunk[1:end-1](dummy), 2)
    feature_width >= horizontal_bins || throw(ArgumentError(
        "horizontal_bins=$(horizontal_bins) exceeds the feature map width $(feature_width) " *
        "produced by image width $(image_size[2]); use fewer bins or a wider input",
    ))

    pooled_dim = size(flatten_batch(trunk(dummy)), 1)
    projection = Dense(pooled_dim => embedding_dim)

    return SymbolEmbeddingModel(trunk, projection, image_size, Int(embedding_dim), Int(horizontal_bins))
end

"""
    split_symbol_sources(labeling_output_dir; enroll_percent=0.75, holdout_label_percent=0.0)

Split labeled tiles into the four buckets described by `SymbolSourceSplit`.
Every returned dataset carries the same full `label_names` list so label indices
are comparable across buckets.
"""
function split_symbol_sources(
    labeling_output_dir::AbstractString;
    enroll_percent::Real=0.75,
    holdout_label_percent::Real=0.0,
    image_size::Union{Nothing,Tuple{Int,Int}}=nothing,
    rng::AbstractRNG=Random.default_rng(),
)
    grouped_paths, _ = group_tile_paths_by_label_dir(labeling_output_dir)
    isempty(grouped_paths) && throw(ArgumentError("No labeled PNG files found in $(labeling_output_dir)"))

    label_names = sort(collect(keys(grouped_paths)))
    enroll_fraction = clamp(normalize_percent(enroll_percent), 0.0, 1.0)
    holdout_fraction = clamp(normalize_percent(holdout_label_percent), 0.0, 1.0)
    holdout_count = clamp(round(Int, holdout_fraction * length(label_names)), 0, max(length(label_names) - 2, 0))
    holdout_labels = Set(shuffle(rng, label_names)[1:holdout_count])

    buckets = Dict(
        name => (masks=BitMatrix[], labels=Int[], paths=String[])
        for name in ("train", "train_query", "holdout_enroll", "holdout_query")
    )
    target_size = image_size

    for (label_index, label) in enumerate(label_names)
        paths = shuffle(rng, grouped_paths[label])
        enroll_count = train_source_count(length(paths), enroll_fraction)
        held_out = label in holdout_labels

        for (path_index, path) in enumerate(paths)
            is_pending_path(path) && throw(ArgumentError("pending image cannot be used for training: $(path)"))
            mask = load_symbol_source_mask(path)
            if isnothing(target_size)
                target_size = size(mask)
            else
                mask = resize_source_mask(mask, target_size)
            end

            is_enrollment = path_index <= enroll_count
            key = held_out ?
                (is_enrollment ? "holdout_enroll" : "holdout_query") :
                (is_enrollment ? "train" : "train_query")
            bucket = buckets[key]
            push!(bucket.masks, BitMatrix(mask))
            push!(bucket.labels, label_index)
            push!(bucket.paths, path)
        end
    end

    isnothing(target_size) && throw(ArgumentError("no source masks could be loaded"))
    build_bucket(key) = isempty(buckets[key].masks) ? nothing : SymbolSourceDataset(
        buckets[key].masks,
        buckets[key].labels,
        copy(label_names),
        buckets[key].paths,
        target_size,
    )

    train = build_bucket("train")
    isnothing(train) && throw(ArgumentError("no training tiles remain after splitting"))

    return SymbolSourceSplit(
        train,
        build_bucket("train_query"),
        build_bucket("holdout_enroll"),
        build_bucket("holdout_query"),
        copy(label_names),
        sort(collect(holdout_labels)),
    )
end

"""
    train_symbol_embedder(labeling_output_dir; kwargs...)

Train the fingerprint network on clean labeled tiles, generating augmentations
on demand. Returns a `SymbolEmbeddingResult` containing the trained model and a
gallery built from the enrollment tiles.

Set `holdout_label_percent` above zero to hold some students out of training
entirely and measure how well the model identifies students it never saw.
Augmentation keyword arguments are forwarded to `augment_black_mask`.
"""
function train_symbol_embedder(
    labeling_output_dir::AbstractString;
    image_size::Union{Nothing,Tuple{Int,Int}}=nothing,
    embedding_dim::Integer=128,
    horizontal_bins::Integer=16,
    batch_size::Integer=32,
    epochs::Integer=40,
    learning_rate::Real=1f-3,
    weight_decay::Real=1f-4,
    margin::Real=0.2,
    scale::Real=16,
    enroll_percent::Real=0.75,
    holdout_label_percent::Real=0.0,
    samples_per_source_per_epoch::Integer=8,
    eval_augmentations_per_source::Integer=4,
    gallery_augmentations_per_source::Integer=8,
    eval_every::Integer=1,
    rng::AbstractRNG=Random.default_rng(),
    verbose::Bool=true,
    kwargs...,
)
    samples_per_source_per_epoch > 0 || throw(ArgumentError("samples_per_source_per_epoch must be positive"))
    eval_every > 0 || throw(ArgumentError("eval_every must be positive"))

    split = split_symbol_sources(
        labeling_output_dir;
        enroll_percent,
        holdout_label_percent,
        image_size,
        rng,
    )
    train = split.train

    model = create_symbol_embedder(train.image_size; embedding_dim, horizontal_bins)
    seen_label_indices = sort(unique(train.labels))
    class_of_label = Dict(label_index => position for (position, label_index) in enumerate(seen_label_indices))
    class_ids = [class_of_label[label] for label in train.labels]
    head = CosineMarginHead(
        Flux.glorot_uniform(embedding_dim, length(seen_label_indices)),
        Float32(margin),
        Float32(scale),
    )

    trainable = (; model, head)
    opt_state = Flux.setup(
        Flux.OptimiserChain(Flux.WeightDecay(Float32(weight_decay)), Flux.Adam(Float32(learning_rate))),
        trainable,
    )
    known_metrics = Dict{String,Any}[]
    holdout_metrics = Dict{String,Any}[]

    if verbose
        println(
            "training on ", length(seen_label_indices), " labels (",
            length(train.labels), " tiles); holding out ",
            length(split.holdout_label_names), " labels",
        )
    end

    for epoch in 1:epochs
        epoch_indices = repeat(collect(eachindex(train.labels)); inner=samples_per_source_per_epoch)
        shuffle!(rng, epoch_indices)
        epoch_loss = 0.0
        batch_count = 0

        for batch_indices in minibatches(epoch_indices, batch_size)
            x = augmented_source_batch(train, batch_indices; rng, kwargs...)
            y = Float32.(Flux.onehotbatch(class_ids[batch_indices], 1:length(seen_label_indices)))

            loss, grads = Flux.withgradient(trainable) do m
                Flux.logitcrossentropy(m.head(m.model(x), y), y)
            end
            Flux.update!(opt_state, trainable, grads[1])
            epoch_loss += Float64(loss)
            batch_count += 1
        end

        should_evaluate = epoch % eval_every == 0 || epoch == epochs
        should_evaluate || continue

        known = evaluate_split_bucket(
            model, train, split.train_query;
            augmentations_per_source=eval_augmentations_per_source, rng, kwargs...,
        )
        isnothing(known) || push!(known_metrics, known)

        holdout = evaluate_split_bucket(
            model, split.holdout_enroll, split.holdout_query;
            augmentations_per_source=eval_augmentations_per_source, rng, kwargs...,
        )
        isnothing(holdout) || push!(holdout_metrics, holdout)

        if verbose
            message = string(
                "epoch=", epoch,
                " loss=", round(epoch_loss / max(batch_count, 1); digits=4),
            )
            isnothing(known) || (message *= string(
                " known_top1=", round(known["accuracy"]; digits=4),
                " known_top3=", round(known["top_k_accuracy"]; digits=4),
            ))
            isnothing(holdout) || (message *= string(
                " new_top1=", round(holdout["accuracy"]; digits=4),
                " new_top3=", round(holdout["top_k_accuracy"]; digits=4),
            ))
            println(message)
        end
    end

    gallery = build_symbol_gallery(
        model, train;
        augmentations_per_source=gallery_augmentations_per_source, rng, kwargs...,
    )

    return SymbolEmbeddingResult(model, split, gallery, known_metrics, holdout_metrics)
end

function evaluate_split_bucket(model, enroll_dataset, query_dataset; kwargs...)
    (isnothing(enroll_dataset) || isnothing(query_dataset)) && return nothing
    gallery = build_symbol_gallery(model, enroll_dataset; kwargs...)
    return evaluate_symbol_gallery(gallery, query_dataset; kwargs...)
end

"""
    build_symbol_gallery(model, dataset; augmentations_per_source=8)

Build a gallery from every label present in `dataset`, averaging each student's
fingerprints across their enrollment tiles and augmented copies of them.
"""
function build_symbol_gallery(
    model::SymbolEmbeddingModel,
    dataset::SymbolSourceDataset;
    augmentations_per_source::Integer=8,
    rng::AbstractRNG=Random.default_rng(),
    kwargs...,
)
    present = sort(unique(dataset.labels))
    label_names = [dataset.label_names[label_index] for label_index in present]
    prototypes = Matrix{Float32}(undef, model.embedding_dim, length(present))

    for (column, label_index) in enumerate(present)
        masks = dataset.masks[findall(==(label_index), dataset.labels)]
        prototypes[:, column] = prototype_from_masks(
            model, masks; augmentations_per_source, rng, kwargs...,
        )
    end

    return SymbolGallery(model, label_names, prototypes)
end

"""
    enroll_symbol!(gallery, label, sources; augmentations_per_source=8)

Add a student to the gallery, or replace their prototype if already present.
`sources` may be a directory, a single image path, or a vector of paths or
images. This does not retrain the model.
"""
function enroll_symbol!(
    gallery::SymbolGallery,
    label::AbstractString,
    sources;
    augmentations_per_source::Integer=8,
    rng::AbstractRNG=Random.default_rng(),
    kwargs...,
)
    masks = load_source_masks(sources, gallery.model.image_size)
    isempty(masks) && throw(ArgumentError("no enrollment images found for label $(label)"))
    prototype = prototype_from_masks(gallery.model, masks; augmentations_per_source, rng, kwargs...)

    existing = findfirst(==(String(label)), gallery.label_names)
    if isnothing(existing)
        push!(gallery.label_names, String(label))
        gallery.prototypes = hcat(gallery.prototypes, prototype)
    else
        gallery.prototypes[:, existing] = prototype
    end

    return gallery
end

"""
    remove_symbol!(gallery, label)

Drop a student from the gallery so they are no longer a candidate match.
"""
function remove_symbol!(gallery::SymbolGallery, label::AbstractString)
    index = findfirst(==(String(label)), gallery.label_names)
    isnothing(index) && throw(ArgumentError("label not in gallery: $(label)"))
    keep = [position for position in eachindex(gallery.label_names) if position != index]
    gallery.label_names = gallery.label_names[keep]
    gallery.prototypes = gallery.prototypes[:, keep]
    return gallery
end

function prototype_from_masks(
    model::SymbolEmbeddingModel,
    masks;
    augmentations_per_source::Integer=8,
    rng::AbstractRNG=Random.default_rng(),
    kwargs...,
)
    images, _ = mask_views_batch(
        masks, model.image_size;
        augmentations_per_source, include_clean=true, rng, kwargs...,
    )
    embeddings = embed_image_batch(model, images)
    return vec(l2_normalize(reshape(mean(embeddings; dims=2), :, 1)))
end

function mask_views_batch(
    masks,
    image_size::Tuple{Int,Int};
    augmentations_per_source::Integer=0,
    include_clean::Bool=true,
    rng::AbstractRNG=Random.default_rng(),
    kwargs...,
)
    views_per_source = augmentations_per_source + (include_clean ? 1 : 0)
    views_per_source > 0 || throw(ArgumentError("each source must produce at least one view"))
    height, width = image_size
    images = Array{Float32,4}(undef, height, width, 1, length(masks) * views_per_source)
    owners = Vector{Int}(undef, size(images, 4))
    position = 0

    for (source_index, mask) in enumerate(masks)
        if include_clean
            position += 1
            images[:, :, 1, position] .= ifelse.(mask, 0.0f0, 1.0f0)
            owners[position] = source_index
        end

        for _ in 1:augmentations_per_source
            position += 1
            augmented = augment_black_mask(mask; rng, kwargs...)
            images[:, :, 1, position] .= Float32.(grayscale_float_image(augmented))
            owners[position] = source_index
        end
    end

    return images, owners
end

function embed_image_batch(model::SymbolEmbeddingModel, images::Array{Float32,4}; chunk_size::Integer=64)
    total = size(images, 4)
    embeddings = Matrix{Float32}(undef, model.embedding_dim, total)

    for start in 1:chunk_size:total
        stop = min(start + chunk_size - 1, total)
        embeddings[:, start:stop] = model(images[:, :, :, start:stop])
    end

    return embeddings
end

"""
    embed_symbol(model, image_or_path)

Return the unit-length fingerprint of one image.
"""
function embed_symbol(model::SymbolEmbeddingModel, image_or_path)
    mask = prepare_source_mask(image_or_path, model.image_size)
    images = Array{Float32,4}(undef, model.image_size[1], model.image_size[2], 1, 1)
    images[:, :, 1, 1] .= ifelse.(mask, 0.0f0, 1.0f0)
    return vec(model(images))
end

"""
    match_symbol(gallery, image_or_path; top_k=3)

Return the `top_k` best-matching students as a vector of `(label, score)`
named tuples, most similar first. Scores are cosine similarities in `[-1, 1]`.
"""
function match_symbol(gallery::SymbolGallery, image_or_path; top_k::Integer=3)
    scores = vec(transpose(gallery.prototypes) * embed_symbol(gallery.model, image_or_path))
    order = sortperm(scores; rev=true)
    kept = order[1:min(top_k, length(order))]
    return [(label=gallery.label_names[index], score=Float64(scores[index])) for index in kept]
end

"""
    symbol_score_matrix(gallery, sources)

Return `(scores, paths)` where `scores[paper, student]` is the cosine similarity
between paper and the gallery prototype for that student.
"""
function symbol_score_matrix(gallery::SymbolGallery, sources)
    paths = collect_source_paths(sources)
    masks = load_source_masks(paths, gallery.model.image_size)
    images, _ = mask_views_batch(
        masks, gallery.model.image_size;
        augmentations_per_source=0, include_clean=true,
    )
    embeddings = embed_image_batch(gallery.model, images)
    return transpose(embeddings) * gallery.prototypes, paths
end

"""
    evaluate_symbol_gallery(gallery, dataset; augmentations_per_source=4, top_k=3)

Score a query dataset against the gallery by nearest prototype. Labels present
in the dataset but absent from the gallery are skipped and reported under
`"skipped"`.
"""
function evaluate_symbol_gallery(
    gallery::SymbolGallery,
    dataset::SymbolSourceDataset;
    augmentations_per_source::Integer=4,
    top_k::Integer=3,
    scale::Real=16,
    rng::AbstractRNG=Random.default_rng(),
    kwargs...,
)
    images, owners = mask_views_batch(
        dataset.masks, dataset.image_size;
        augmentations_per_source, include_clean=true, rng, kwargs...,
    )
    embeddings = embed_image_batch(gallery.model, images)
    scores = transpose(gallery.prototypes) * embeddings

    column_of_label = Dict(name => index for (index, name) in enumerate(gallery.label_names))
    truth = Int[]
    kept_columns = Int[]

    for (view_index, source_index) in enumerate(owners)
        name = dataset.label_names[dataset.labels[source_index]]
        column = get(column_of_label, name, nothing)
        isnothing(column) && continue
        push!(truth, column)
        push!(kept_columns, view_index)
    end

    isempty(truth) && throw(ArgumentError("no query labels are present in the gallery"))
    scores = scores[:, kept_columns]
    predictions = [argmax(view(scores, :, index)) for index in axes(scores, 2)]

    effective_k = min(top_k, size(scores, 1))
    top_k_hits = 0
    for index in axes(scores, 2)
        ranked = partialsortperm(view(scores, :, index), 1:effective_k; rev=true)
        truth[index] in ranked && (top_k_hits += 1)
    end

    loss = Flux.logitcrossentropy(
        Float32(scale) .* scores,
        Float32.(Flux.onehotbatch(truth, 1:length(gallery.label_names))),
    )
    metrics = classification_metrics(
        predictions,
        truth,
        gallery.label_names;
        loss=Float64(loss),
        samples_per_source=augmentations_per_source + 1,
    )
    metrics["top_k"] = effective_k
    metrics["top_k_accuracy"] = top_k_hits / length(truth)
    metrics["skipped"] = size(embeddings, 2) - length(truth)
    metrics["mean_top_score"] = mean(maximum(scores; dims=1))
    return metrics
end

"""
    assign_symbols_to_roster(gallery, sources; roster=gallery.label_names, allow_unassigned=false, reject_score=0.0)

Assign a stack of scanned papers to students so that each student receives at
most one paper and the total similarity is maximized. Solving the whole stack at
once beats matching each paper independently, because a confident match claims
its student and removes that student as a distractor for the ambiguous papers.

Having fewer papers than students is handled directly; the leftover students are
simply unmatched. `allow_unassigned` covers the different problem of a paper
belonging to nobody on the roster (an unenrolled writer, an illegible field, a
duplicate scan). Without it, such a paper is forced onto whichever student fits
it least badly and displaces that student's real paper. With it, any paper whose
best score falls below `reject_score` drops out instead.

Returns a vector of named tuples with `path`, `label` (`nothing` when
unassigned), `score`, and `alternatives` (the independent top matches, for
review).
"""
function assign_symbols_to_roster(
    gallery::SymbolGallery,
    sources;
    roster::Vector{String}=gallery.label_names,
    allow_unassigned::Bool=false,
    reject_score::Real=0.0,
    top_k::Integer=3,
)
    scores, paths = symbol_score_matrix(gallery, sources)
    column_of_label = Dict(name => index for (index, name) in enumerate(gallery.label_names))
    missing_labels = [name for name in roster if !haskey(column_of_label, name)]
    isempty(missing_labels) ||
        throw(ArgumentError("roster names are not enrolled in the gallery: $(join(missing_labels, ", "))"))

    roster_columns = [column_of_label[name] for name in roster]
    roster_scores = scores[:, roster_columns]
    paper_count = size(roster_scores, 1)

    cost = Matrix{Float64}(-roster_scores)
    if allow_unassigned
        cost = hcat(cost, fill(-Float64(reject_score), paper_count, paper_count))
    end

    paper_count <= size(cost, 2) || throw(ArgumentError(
        "there are $(paper_count) papers but only $(size(cost, 2)) available slots; " *
        "pass allow_unassigned=true or widen the roster",
    ))

    assignment, _ = hungarian(cost)
    results = Vector{NamedTuple}(undef, paper_count)

    for paper in 1:paper_count
        column = assignment[paper]
        order = sortperm(view(roster_scores, paper, :); rev=true)
        alternatives = [
            (label=roster[index], score=Float64(roster_scores[paper, index]))
            for index in order[1:min(top_k, length(order))]
        ]

        assigned = column != 0 && column <= length(roster)
        results[paper] = (
            path=paths[paper],
            label=assigned ? roster[column] : nothing,
            score=assigned ? Float64(roster_scores[paper, column]) : NaN,
            alternatives=alternatives,
        )
    end

    return results
end

"""
    print_assignment_report(results; review_below=nothing)

Print one line per paper. Papers scoring below `review_below`, and papers left
unassigned, are flagged with `*`.
"""
function print_assignment_report(results; review_below::Union{Nothing,Real}=nothing)
    println(rpad("paper", 42), rpad("assigned", 16), rpad("score", 9), "runners-up")

    for result in results
        needs_review = isnothing(result.label) ||
            (!isnothing(review_below) && result.score < review_below)
        runners_up = join(
            [string(alternative.label, " ", round(alternative.score; digits=3))
             for alternative in result.alternatives[2:min(3, length(result.alternatives))]],
            ", ",
        )
        println(
            rpad(truncate_text(basename(result.path), 40), 42),
            rpad(isnothing(result.label) ? "-" : result.label, 16),
            rpad(isnan(result.score) ? "-" : string(round(result.score; digits=3)), 9),
            runners_up,
            needs_review ? "  *" : "",
        )
    end

    return nothing
end

function print_symbol_metrics(metrics::AbstractDict; title::AbstractString="metrics")
    println(
        title,
        ": top1=", round(metrics["accuracy"]; digits=4),
        " top", metrics["top_k"], "=", round(metrics["top_k_accuracy"]; digits=4),
        " correct=", metrics["correct"], "/", metrics["total"],
        " mean_top_score=", round(metrics["mean_top_score"]; digits=4),
    )
    return nothing
end

function truncate_text(text::AbstractString, width::Integer)
    return length(text) <= width ? text : text[1:width]
end

function collect_source_paths(sources)
    if sources isa AbstractString
        isdir(sources) && return filter(!is_pending_path, sorted_png_files(sources))
        isfile(sources) && return [String(sources)]
        throw(ArgumentError("source path does not exist: $(sources)"))
    end

    return collect(sources)
end

function load_source_masks(sources, image_size::Tuple{Int,Int})
    return [prepare_source_mask(source, image_size) for source in collect_source_paths(sources)]
end

function prepare_source_mask(source, image_size::Tuple{Int,Int})
    mask = source isa AbstractString ? load_symbol_source_mask(source) : source_mask_from_image(source)
    return resize_source_mask(mask, image_size)
end

function source_mask_from_image(image)
    mask = bitmap_black_mask(image)
    return isnothing(mask) ? (grayscale_float_image(image) .< 0.5) : mask
end

"""
    save_symbol_embedder(model, path)
    save_symbol_gallery(gallery, path)

Persist a trained model or a gallery with Julia serialization. Keep the original
enrollment images: prototypes are produced by the model, so retraining the model
invalidates every stored prototype and the gallery must be rebuilt.
"""
function save_symbol_embedder(model::SymbolEmbeddingModel, path::AbstractString)
    return serialize_to_path(model, path)
end

save_symbol_embedder(result::SymbolEmbeddingResult, path::AbstractString) =
    save_symbol_embedder(result.model, path)

function load_symbol_embedder(path::AbstractString)
    model = open(deserialize, path)
    model isa SymbolEmbeddingModel || throw(ArgumentError("file does not contain a SymbolEmbeddingModel"))
    return model
end

function save_symbol_gallery(gallery::SymbolGallery, path::AbstractString)
    return serialize_to_path(gallery, path)
end

save_symbol_gallery(result::SymbolEmbeddingResult, path::AbstractString) =
    save_symbol_gallery(result.gallery, path)

function load_symbol_gallery(path::AbstractString)
    gallery = open(deserialize, path)
    gallery isa SymbolGallery || throw(ArgumentError("file does not contain a SymbolGallery"))
    return gallery
end

function serialize_to_path(value, path::AbstractString)
    parent = dirname(path)
    isempty(parent) || mkpath(parent)
    open(path, "w") do io
        serialize(io, value)
    end
    return path
end

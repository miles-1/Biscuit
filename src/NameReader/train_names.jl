using Flux
using Random
using Statistics

struct NameHandwritingDataset
    images::Vector{Matrix{Float32}}
    labels::Vector{Int}
    label_names::Vector{String}
    paths::Vector{String}
    image_size::Tuple{Int,Int}
end

struct NameReaderBundle
    gallery::SymbolGallery
    image_size::Tuple{Int,Int}
    morphology_radius::Int
    isolated_pixel_radius::Int
    threshold::Float32
end

"""
    train_name_reader(handwriting_dir; kwargs...)

Train the name embedding network on per-student handwriting folders (as exported
by grading) composited onto scanned blank name fields.

Keyword arguments include `background_dir`, `output_path` (a `.namereader` file),
and the usual embedder hyperparameters. Augmentation magnitudes are those of
`compose_name_training_image`.
"""
function train_name_reader(
    handwriting_dir::AbstractString;
    background_dir::AbstractString=background_training_dir(),
    output_path::Union{Nothing,AbstractString}=nothing,
    image_size::Tuple{Int,Int}=NAME_FIELD_SIZE,
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
    morphology_radius::Integer=1,
    isolated_pixel_radius::Integer=1,
    rng::AbstractRNG=Random.default_rng(),
    verbose::Bool=true,
    preview_count::Integer=8,
    should_stop::Function=() -> false,
    save_on_stop::Function=() -> true,
    kwargs...,
)
    samples_per_source_per_epoch > 0 || throw(ArgumentError("samples_per_source_per_epoch must be positive"))
    eval_every > 0 || throw(ArgumentError("eval_every must be positive"))

    split = split_name_handwriting(handwriting_dir; enroll_percent, holdout_label_percent, image_size, rng)
    backgrounds = load_background_images(background_dir; target_size=image_size)
    train = split.train

    compose_kwargs = (; morphology_radius, isolated_pixel_radius, kwargs...)

    if verbose
        n_train = length(train.labels)
        n_per_epoch = n_train * samples_per_source_per_epoch
        n_query = isnothing(split.train_query) ? 0 : length(split.train_query.labels)
        println(
            "training on ", length(unique(train.labels)), " students (",
            n_train, " handwriting crops, ",
            length(backgrounds), " background(s); random background per sample)",
        )
        println(
            "images per epoch: ", n_per_epoch,
            " (", n_train, " train crops × ", samples_per_source_per_epoch, " overlays)",
        )
        if n_query > 0
            println(
                "guess accuracy evaluated on ", n_query,
                " held-out crops from those same students (testing data set)",
            )
        end
        flush(stdout)
    end

    if preview_count > 0
        preview_dir = _overlay_preview_dir(handwriting_dir, output_path)
        preview_name_training_samples(
            handwriting_dir, preview_dir;
            n=preview_count, backgrounds, image_size, rng, compose_kwargs...,
        )
        println("Wrote $(preview_count) random overlay preview(s): ", preview_dir)
        flush(stdout)
    end

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
    stopped_early = false
    last_epoch = 0

    for epoch in 1:epochs
        if should_stop()
            stopped_early = true
            break
        end

        epoch_indices = repeat(collect(eachindex(train.labels)); inner=samples_per_source_per_epoch)
        shuffle!(rng, epoch_indices)
        epoch_loss = 0.0
        batch_count = 0

        for batch_indices in minibatches(epoch_indices, batch_size)
            if should_stop()
                stopped_early = true
                break
            end
            x = composed_name_batch(train, backgrounds, batch_indices; rng, compose_kwargs...)
            y = Float32.(Flux.onehotbatch(class_ids[batch_indices], 1:length(seen_label_indices)))

            loss, grads = Flux.withgradient(trainable) do m
                Flux.logitcrossentropy(m.head(m.model(x), y), y)
            end
            Flux.update!(opt_state, trainable, grads[1])
            epoch_loss += Float64(loss)
            batch_count += 1
        end

        want_save = save_on_stop()
        if stopped_early && !want_save
            break
        end

        batch_count == 0 && break
        last_epoch = epoch

        should_evaluate = epoch % eval_every == 0 || epoch == epochs || stopped_early
        known = nothing
        holdout = nothing
        if should_evaluate
            known = evaluate_name_split_bucket(
                model, train, split.train_query, backgrounds;
                augmentations_per_source=eval_augmentations_per_source, rng, compose_kwargs...,
            )
            isnothing(known) || push!(known_metrics, known)

            holdout = evaluate_name_split_bucket(
                model, split.holdout_enroll, split.holdout_query, backgrounds;
                augmentations_per_source=eval_augmentations_per_source, rng, compose_kwargs...,
            )
            isnothing(holdout) || push!(holdout_metrics, holdout)
        end

        if verbose && should_evaluate
            println(_format_epoch_line(
                epoch, epochs, epoch_loss / max(batch_count, 1);
                known, holdout,
            ))
            flush(stdout)
        end
        stopped_early && break
    end

    want_save = last_epoch > 0 && (!stopped_early || save_on_stop())
    if verbose && stopped_early
        if !want_save
            println("Training cancelled; model not saved.")
        else
            println("Stopping early after epoch $last_epoch/$epochs; saving the current model.")
        end
        flush(stdout)
    end

    if !want_save
        return nothing, nothing
    end

    gallery = build_name_gallery(
        model, train, backgrounds;
        augmentations_per_source=gallery_augmentations_per_source, rng, compose_kwargs...,
    )
    bundle = NameReaderBundle(
        gallery,
        train.image_size,
        Int(morphology_radius),
        Int(isolated_pixel_radius),
        0.5f0,
    )

    if output_path !== nothing && !isempty(strip(String(output_path)))
        save_name_reader(bundle, output_path)
        println("Wrote: ", output_path)
    end

    return SymbolEmbeddingResult(model, split_as_symbol_sources(split), gallery, known_metrics, holdout_metrics), bundle
end

function _format_epoch_line(epoch, epochs, loss; known=nothing, holdout=nothing)
    round4rpad6(num) = rpad(round(num; digits=4), 6, "0")
    epoch = lpad(epoch, 2)
    loss = round4rpad6(loss)
    first_guess_correct = round4rpad6(known["accuracy"])
    correct_within_3_guesses = round4rpad6(known["top_k_accuracy"])
    return "epoch=$epoch/$epochs loss=$loss first_guess_correct=$first_guess_correct correct_within_3_guesses=$correct_within_3_guesses"
end

function split_name_handwriting(
    handwriting_dir::AbstractString;
    enroll_percent::Real=0.75,
    holdout_label_percent::Real=0.0,
    image_size::Tuple{Int,Int}=NAME_FIELD_SIZE,
    rng::AbstractRNG=Random.default_rng(),
)
    grouped_paths, _ = group_tile_paths_by_label_dir(handwriting_dir)
    isempty(grouped_paths) && throw(ArgumentError("No labeled PNG files found in $(handwriting_dir)"))

    label_names = sort(collect(keys(grouped_paths)))
    enroll_fraction = clamp(normalize_percent(enroll_percent), 0.0, 1.0)
    holdout_fraction = clamp(normalize_percent(holdout_label_percent), 0.0, 1.0)
    holdout_count = clamp(round(Int, holdout_fraction * length(label_names)), 0, max(length(label_names) - 2, 0))
    holdout_labels = Set(shuffle(rng, label_names)[1:holdout_count])

    buckets = Dict(
        name => (images=Matrix{Float32}[], labels=Int[], paths=String[])
        for name in ("train", "train_query", "holdout_enroll", "holdout_query")
    )

    for (label_index, label) in enumerate(label_names)
        paths = shuffle(rng, grouped_paths[label])
        enroll_count = train_source_count(length(paths), enroll_fraction)
        held_out = label in holdout_labels

        for (path_index, path) in enumerate(paths)
            is_pending_path(path) && throw(ArgumentError("pending image cannot be used for training: $(path)"))
            gray = fit_to_name_canvas(grayscale_float_image(load(path)), image_size; align=:baseline)
            is_enrollment = path_index <= enroll_count
            key = held_out ?
                (is_enrollment ? "holdout_enroll" : "holdout_query") :
                (is_enrollment ? "train" : "train_query")
            bucket = buckets[key]
            push!(bucket.images, gray)
            push!(bucket.labels, label_index)
            push!(bucket.paths, path)
        end
    end

    build_bucket(key) = isempty(buckets[key].images) ? nothing : NameHandwritingDataset(
        buckets[key].images,
        buckets[key].labels,
        copy(label_names),
        buckets[key].paths,
        image_size,
    )

    train = build_bucket("train")
    isnothing(train) && throw(ArgumentError("no training tiles remain after splitting"))

    return (
        train=train,
        train_query=build_bucket("train_query"),
        holdout_enroll=build_bucket("holdout_enroll"),
        holdout_query=build_bucket("holdout_query"),
        label_names=copy(label_names),
        holdout_label_names=sort(collect(holdout_labels)),
    )
end

function composed_name_batch(
    dataset::NameHandwritingDataset,
    backgrounds,
    batch_indices;
    rng::AbstractRNG,
    kwargs...,
)
    height, width = dataset.image_size
    images = Array{Float32,4}(undef, height, width, 1, length(batch_indices))

    for (batch_position, source_index) in enumerate(batch_indices)
        background = backgrounds[rand(rng, eachindex(backgrounds))]
        composed = compose_name_training_image(
            dataset.images[source_index],
            background;
            target_size=dataset.image_size,
            rng,
            kwargs...,
        )
        images[:, :, 1, batch_position] .= Float32.(grayscale_float_image(composed))
    end

    return images
end

function build_name_gallery(
    model::SymbolEmbeddingModel,
    dataset::NameHandwritingDataset,
    backgrounds;
    augmentations_per_source::Integer=8,
    rng::AbstractRNG=Random.default_rng(),
    kwargs...,
)
    present = sort(unique(dataset.labels))
    label_names = [dataset.label_names[label_index] for label_index in present]
    prototypes = Matrix{Float32}(undef, model.embedding_dim, length(present))

    for (column, label_index) in enumerate(present)
        source_indices = findall(==(label_index), dataset.labels)
        images = composed_name_batch(
            dataset, backgrounds, repeat(source_indices; inner=max(1, augmentations_per_source));
            rng, kwargs...,
        )
        embeddings = embed_image_batch(model, images)
        prototypes[:, column] = vec(l2_normalize(reshape(mean(embeddings; dims=2), :, 1)))
    end

    return SymbolGallery(model, label_names, prototypes)
end

function evaluate_name_split_bucket(model, enroll_dataset, query_dataset, backgrounds; kwargs...)
    (isnothing(enroll_dataset) || isnothing(query_dataset)) && return nothing
    gallery = build_name_gallery(model, enroll_dataset, backgrounds; kwargs...)
    return evaluate_name_gallery(gallery, query_dataset, backgrounds; kwargs...)
end

function evaluate_name_gallery(
    gallery::SymbolGallery,
    dataset::NameHandwritingDataset,
    backgrounds;
    augmentations_per_source::Integer=4,
    top_k::Integer=3,
    scale::Real=16,
    rng::AbstractRNG=Random.default_rng(),
    kwargs...,
)
    indices = repeat(collect(eachindex(dataset.labels)); inner=max(1, augmentations_per_source))
    images = composed_name_batch(dataset, backgrounds, indices; rng, kwargs...)
    embeddings = embed_image_batch(gallery.model, images)
    scores = transpose(gallery.prototypes) * embeddings

    column_of_label = Dict(name => index for (index, name) in enumerate(gallery.label_names))
    truth = Int[]
    kept_columns = Int[]

    for (view_index, source_index) in enumerate(indices)
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
        samples_per_source=augmentations_per_source,
    )
    metrics["top_k"] = effective_k
    metrics["top_k_accuracy"] = top_k_hits / length(truth)
    metrics["skipped"] = size(embeddings, 2) - length(truth)
    metrics["mean_top_score"] = mean(maximum(scores; dims=1))
    return metrics
end

function split_as_symbol_sources(split)
    to_symbol(ds) = isnothing(ds) ? nothing : SymbolSourceDataset(
        [gray .< 0.5 for gray in ds.images],
        ds.labels,
        ds.label_names,
        ds.paths,
        ds.image_size,
    )
    return SymbolSourceSplit(
        to_symbol(split.train),
        to_symbol(split.train_query),
        to_symbol(split.holdout_enroll),
        to_symbol(split.holdout_query),
        split.label_names,
        split.holdout_label_names,
    )
end

"""
    save_name_reader(bundle, path)
    load_name_reader(path)

Persist a trained `NameReaderBundle` as a `.namereader` file (Julia serialization).
"""
function save_name_reader(bundle::NameReaderBundle, path::AbstractString)
    dest = String(path)
    if !endswith(lowercase(dest), ".namereader")
        dest = dest * ".namereader"
    end
    return serialize_to_path(bundle, dest)
end

save_name_reader(gallery::SymbolGallery, path::AbstractString) =
    save_name_reader(NameReaderBundle(gallery, gallery.model.image_size, 1, 1, 0.5f0), path)

function load_name_reader(path::AbstractString)
    value = open(deserialize, path)
    value isa NameReaderBundle && return value
    value isa SymbolGallery && return NameReaderBundle(value, value.model.image_size, 1, 1, 0.5f0)
    throw(ArgumentError("file does not contain a NameReaderBundle: $(path)"))
end

"""
    guess_assignment_names(bundle, crops; roster=nothing, allow_unassigned=true, reject_score=0.15)

Assign each prepared name-field crop to a unique student via the Hungarian
algorithm. `crops` is a vector of grayscale images (already cropped). Returns
a vector of named tuples `(index, label, score, alternatives)`.
"""
function guess_assignment_names(
    bundle::NameReaderBundle,
    crops;
    roster::Union{Nothing,Vector{String}}=nothing,
    allow_unassigned::Bool=true,
    reject_score::Real=0.15,
    top_k::Integer=3,
)
    prepared = [prepare_name_crop(bundle, crop) for crop in crops]
    names = isnothing(roster) ? bundle.gallery.label_names : roster
    results = assign_symbols_to_roster(
        bundle.gallery,
        prepared;
        roster=intersect_roster(names, bundle.gallery.label_names),
        allow_unassigned,
        reject_score,
        top_k,
    )
    return [
        (index=i, label=r.label, score=r.score, alternatives=r.alternatives)
        for (i, r) in enumerate(results)
    ]
end

function intersect_roster(requested::Vector{String}, enrolled::Vector{String})
    enrolled_set = Set(enrolled)
    kept = [name for name in requested if name in enrolled_set]
    !isempty(kept) && return kept

    enrolled_by_key = Dict(_person_key(name) => name for name in enrolled)
    mapped = String[]
    seen = Set{String}()
    for name in requested
        gallery_name = get(enrolled_by_key, _person_key(name), nothing)
        gallery_name === nothing && continue
        gallery_name in seen && continue
        push!(mapped, gallery_name)
        push!(seen, gallery_name)
    end
    return isempty(mapped) ? enrolled : mapped
end

function _person_key(name::AbstractString)
    compact = lowercase(replace(strip(String(name)), r"[\s]+" => ""))
    return replace(compact, '_' => ',')
end

function prepare_name_crop(bundle::NameReaderBundle, crop)
    gray = crop isa AbstractMatrix ? grayscale_float_image(crop) : grayscale_float_image(load(crop))
    fitted = fit_to_name_canvas(gray, bundle.image_size; align=:center)
    return prepare_name_image(
        fitted;
        threshold=bundle.threshold,
        morphology_radius=bundle.morphology_radius,
        isolated_pixel_radius=bundle.isolated_pixel_radius,
    )
end

function _overlay_preview_dir(handwriting_dir::AbstractString, output_path)::String
    parent = dirname(abspath(handwriting_dir))
    stem = if output_path !== nothing && !isempty(strip(String(output_path)))
        first(splitext(basename(String(output_path))))
    else
        class_stem_from_training_dir(handwriting_dir)
    end
    return joinpath(parent, stem * "_example_overlays")
end

"""
    class_stem_from_training_dir(handwriting_dir)

Folder `EvolutionFa26_name_training_data` → `EvolutionFa26`. Used as the
`.namereader` / overlay stem. If the suffix is missing, the folder name is used as-is.
"""
function class_stem_from_training_dir(handwriting_dir::AbstractString)::String
    stem = basename(abspath(String(handwriting_dir)))
    suffix = "_name_training_data"
    if endswith(lowercase(stem), suffix) && length(stem) > length(suffix)
        return stem[1:end-length(suffix)]
    end
    return stem
end

"""
    preview_name_training_samples(handwriting_dir, output_dir; n=16, background_dir=...)

Write `n` composed+thinned previews so overlay quality can be inspected before
a long training run.
"""
function preview_name_training_samples(
    handwriting_dir::AbstractString,
    output_dir::AbstractString;
    n::Integer=16,
    background_dir::AbstractString=background_training_dir(),
    backgrounds=nothing,
    image_size::Tuple{Int,Int}=NAME_FIELD_SIZE,
    rng::AbstractRNG=Random.default_rng(),
    kwargs...,
)
    grouped, _ = group_tile_paths_by_label_dir(handwriting_dir)
    isempty(grouped) && throw(ArgumentError("No labeled PNG files found in $(handwriting_dir)"))
    bgs = backgrounds === nothing ? load_background_images(background_dir; target_size=image_size) : backgrounds
    mkpath(output_dir)

    labels = collect(keys(grouped))
    paths = String[]
    for i in 1:n
        label = labels[rand(rng, eachindex(labels))]
        hand_path = grouped[label][rand(rng, eachindex(grouped[label]))]
        hand = fit_to_name_canvas(grayscale_float_image(load(hand_path)), image_size; align=:baseline)
        bg = bgs[rand(rng, eachindex(bgs))]
        composed = compose_name_training_image(hand, bg; target_size=image_size, rng, kwargs...)
        dest = joinpath(output_dir, string("preview-", lpad(string(i), 3, "0"), ".png"))
        save(dest, composed)
        push!(paths, dest)
    end
    return paths
end

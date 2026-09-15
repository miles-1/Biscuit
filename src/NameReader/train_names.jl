using Dates
using Flux
using JSON
using Random
using Statistics

"""
Handwriting samples carry their origin in the file name, because the two origins
have to be augmented differently and split independently.

- `table_<id>.png` came from an assignment's handwritten name table, so it is a
  bare crop of ink that must be composited onto a scanned blank name line.
- `assn_<id>.png` came from the printed name line of a scanned assignment, so it
  is already sitting on real paper.

`<id>` is a content hash, which makes a sample's name stable across exports and
lets the training sidecar refer to samples compactly. Neither prefix may end in
`-<digits>`, which `label_from_filename` would read as a label.
"""
const NAME_TABLE_IMAGE_PREFIX = "table_"
const ASSIGNMENT_IMAGE_PREFIX = "assn_"
const NAME_IMAGE_KINDS = (:table, :assn)
const TRAINING_SIDECAR_VERSION = 1

"""
    name_image_kind(path)

`:assn` for a name-line crop, `:table` otherwise. Files that predate the prefix
convention are treated as name-table crops, which is what they were.
"""
function name_image_kind(path::AbstractString)::Symbol
    return startswith(basename(String(path)), ASSIGNMENT_IMAGE_PREFIX) ? :assn : :table
end

"""
    name_image_id(path)

The content hash in `table_<id>.png` / `assn_<id>.png`, or the bare stem for
files that predate the convention.
"""
function name_image_id(path::AbstractString)::String
    stem = first(splitext(basename(String(path))))
    for prefix in (NAME_TABLE_IMAGE_PREFIX, ASSIGNMENT_IMAGE_PREFIX)
        startswith(stem, prefix) && return chopprefix(stem, prefix)
    end
    return stem
end

name_image_prefix(kind::Symbol)::String =
    kind === :assn ? ASSIGNMENT_IMAGE_PREFIX :
    kind === :table ? NAME_TABLE_IMAGE_PREFIX :
    throw(ArgumentError("unknown name image kind: $(repr(kind))"))

"""
    group_name_paths_by_student(dir)

`dir/<student>/<prefix><id>.png` → `student => (kind => sorted paths)`. Every
student gets an entry for both kinds, possibly empty.
"""
function group_name_paths_by_student(dir::AbstractString)
    grouped, _ = group_tile_paths_by_label_dir(dir)
    by_student = Dict{String,Dict{Symbol,Vector{String}}}()
    for (label, paths) in grouped
        by_kind = Dict{Symbol,Vector{String}}(kind => String[] for kind in NAME_IMAGE_KINDS)
        for path in sort(paths)
            push!(by_kind[name_image_kind(path)], path)
        end
        by_student[label] = by_kind
    end
    return by_student
end

struct NameHandwritingDataset
    images::Vector{Matrix{Float32}}
    labels::Vector{Int}
    label_names::Vector{String}
    paths::Vector{String}
    kinds::Vector{Symbol}
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

Train the name embedding network on per-student handwriting folders. Name-table
crops are composited onto scanned blank name fields; name-line crops taken
straight off a scan are used as they are (see `compose_assignment_training_image`).

Keyword arguments include `background_dir`, `output_path` (a `.namereader` file),
and the usual embedder hyperparameters. Augmentation magnitudes are those of
`compose_name_training_image`.

Pass `init_model` (the `gallery.model` of an existing bundle) to fine-tune: the
backbone starts from those weights instead of a fresh initialisation. The margin
head is always rebuilt, since it is sized to the current student list and is
discarded after training anyway.

`sidecar_path` records which samples landed in which bucket, alongside the saved
bundle. Feed that file's `students` map back in as `previous_split` on the next
run so existing samples keep their bucket.
"""
function train_name_reader(
    handwriting_dir::AbstractString;
    background_dir::AbstractString=background_training_dir(),
    output_path::Union{Nothing,AbstractString}=nothing,
    sidecar_path::Union{Nothing,AbstractString}=nothing,
    init_model::Union{Nothing,SymbolEmbeddingModel}=nothing,
    previous_split::Union{Nothing,AbstractDict}=nothing,
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

    split = split_name_handwriting(
        handwriting_dir;
        enroll_percent, holdout_label_percent, image_size, rng, previous_split,
    )
    backgrounds = load_background_images(background_dir; target_size=image_size)
    train = split.train

    compose_kwargs = (; morphology_radius, isolated_pixel_radius, kwargs...)

    if verbose
        n_train = length(train.labels)
        n_per_epoch = n_train * samples_per_source_per_epoch
        n_query = isnothing(split.train_query) ? 0 : length(split.train_query.labels)
        train_kinds = _kind_counts(train)
        println(
            init_model === nothing ? "training" : "fine-tuning",
            " on ", length(unique(train.labels)), " students (",
            train_kinds[:table], " name-table crop(s) overlaid on ",
            length(backgrounds), " background(s), ",
            train_kinds[:assn], " name-line crop(s) used as scanned)",
        )
        println(
            "images per epoch: ", n_per_epoch,
            " (", n_train, " train crops × ", samples_per_source_per_epoch, " overlays)",
        )
        if n_query > 0
            query_kinds = _kind_counts(split.train_query)
            println(
                "guess accuracy evaluated on ", n_query,
                " held-out crops from those same students (testing data set: ",
                query_kinds[:table], " name-table, ", query_kinds[:assn], " name-line)",
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

    model = if init_model === nothing
        create_symbol_embedder(train.image_size; embedding_dim, horizontal_bins)
    else
        init_model.image_size == train.image_size || throw(ArgumentError(
            "cannot fine-tune: the existing model expects $(init_model.image_size) images " *
            "but training data is $(train.image_size)"
        ))
        init_model
    end
    embedding_dim = model.embedding_dim
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

    if sidecar_path !== nothing && !isempty(strip(String(sidecar_path)))
        write_training_sidecar(sidecar_path, Dict{String,Any}(
            "version" => TRAINING_SIDECAR_VERSION,
            "trained_at" => string(Dates.now()),
            "fine_tuned" => init_model !== nothing,
            "epochs_run" => last_epoch,
            "enroll_percent" => clamp(normalize_percent(enroll_percent), 0.0, 1.0),
            "image_size" => collect(train.image_size),
            "students" => split.split_record,
            "holdout_students" => split.holdout_label_names,
        ))
        println("Wrote: ", sidecar_path)
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

"""
    assign_enrollment_buckets(paths, enroll_fraction; previous, rng)

Decide which of a student's samples enroll (build the gallery prototype) and
which are held back to query it, for one origin kind.

A sample already listed in `previous` keeps the bucket it had, so fine-tuning
never promotes a test sample into training. Only samples absent from `previous`
are split fresh, at `enroll_fraction`. Returns `id => "enroll" | "query"`.
"""
function assign_enrollment_buckets(
    paths::Vector{String},
    enroll_fraction::Real;
    previous::AbstractDict=Dict{String,String}(),
    rng::AbstractRNG=Random.default_rng(),
)
    buckets = Dict{String,String}()
    fresh = String[]
    for path in paths
        id = name_image_id(path)
        known = get(previous, id, nothing)
        known === nothing ? push!(fresh, id) : (buckets[id] = String(known))
    end

    shuffle!(rng, fresh)
    enroll_count = train_source_count(length(fresh), enroll_fraction)
    for (position, id) in enumerate(fresh)
        buckets[id] = position <= enroll_count ? "enroll" : "query"
    end
    return buckets
end

# A student with no enrolled sample gets no gallery prototype and so can never be
# matched. That can only happen through a sticky split (every remaining sample was
# previously a query sample), so move one over rather than dropping the student.
function ensure_one_enrollment!(buckets_by_kind::AbstractDict)
    any(bs -> any(==("enroll"), values(bs)), values(buckets_by_kind)) && return buckets_by_kind
    for kind in NAME_IMAGE_KINDS
        buckets = get(buckets_by_kind, kind, nothing)
        (buckets === nothing || isempty(buckets)) && continue
        buckets[first(sort!(collect(keys(buckets))))] = "enroll"
        return buckets_by_kind
    end
    return buckets_by_kind
end

"""
    split_name_handwriting(handwriting_dir; previous_split=nothing, kwargs...)

Split `handwriting_dir/<student>/<prefix><id>.png` into enrollment and query
sets. Name-table and name-line samples are split independently of each other, so
adding a batch of one kind cannot skew the other kind's split.

`previous_split` is a training sidecar's `students` map; samples it already
records keep their bucket.
"""
function split_name_handwriting(
    handwriting_dir::AbstractString;
    enroll_percent::Real=0.75,
    holdout_label_percent::Real=0.0,
    image_size::Tuple{Int,Int}=NAME_FIELD_SIZE,
    rng::AbstractRNG=Random.default_rng(),
    previous_split::Union{Nothing,AbstractDict}=nothing,
)
    by_student = group_name_paths_by_student(handwriting_dir)
    isempty(by_student) && throw(ArgumentError("No labeled PNG files found in $(handwriting_dir)"))

    label_names = sort(collect(keys(by_student)))
    enroll_fraction = clamp(normalize_percent(enroll_percent), 0.0, 1.0)
    holdout_fraction = clamp(normalize_percent(holdout_label_percent), 0.0, 1.0)
    holdout_count = clamp(round(Int, holdout_fraction * length(label_names)), 0, max(length(label_names) - 2, 0))
    holdout_labels = Set(shuffle(rng, label_names)[1:holdout_count])

    buckets = Dict(
        name => (images=Matrix{Float32}[], labels=Int[], paths=String[], kinds=Symbol[])
        for name in ("train", "train_query", "holdout_enroll", "holdout_query")
    )
    split_record = Dict{String,Any}()

    for (label_index, label) in enumerate(label_names)
        held_out = label in holdout_labels
        student_previous = _sidecar_student_buckets(previous_split, label)
        buckets_by_kind = Dict{Symbol,Dict{String,String}}()
        for kind in NAME_IMAGE_KINDS
            paths = by_student[label][kind]
            isempty(paths) && continue
            buckets_by_kind[kind] = assign_enrollment_buckets(
                paths, enroll_fraction;
                previous=get(student_previous, kind, Dict{String,String}()),
                rng,
            )
        end
        ensure_one_enrollment!(buckets_by_kind)

        for kind in NAME_IMAGE_KINDS
            haskey(buckets_by_kind, kind) || continue
            for path in by_student[label][kind]
                is_pending_path(path) && throw(ArgumentError("pending image cannot be used for training: $(path)"))
                # Name-table crops are bare ink and get sat on the printed line at compose
                # time; name-line crops already include their line and must not be moved.
                align = kind === :assn ? :center : :baseline
                gray = fit_to_name_canvas(grayscale_float_image(load(path)), image_size; align)
                is_enrollment = buckets_by_kind[kind][name_image_id(path)] == "enroll"
                key = held_out ?
                    (is_enrollment ? "holdout_enroll" : "holdout_query") :
                    (is_enrollment ? "train" : "train_query")
                bucket = buckets[key]
                push!(bucket.images, gray)
                push!(bucket.labels, label_index)
                push!(bucket.paths, path)
                push!(bucket.kinds, kind)
            end
        end
        split_record[label] = _split_record_for_student(buckets_by_kind)
    end

    build_bucket(key) = isempty(buckets[key].images) ? nothing : NameHandwritingDataset(
        buckets[key].images,
        buckets[key].labels,
        copy(label_names),
        buckets[key].paths,
        buckets[key].kinds,
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
        split_record=split_record,
    )
end

function _split_record_for_student(buckets_by_kind::AbstractDict)
    record = Dict{String,Any}()
    for kind in NAME_IMAGE_KINDS
        buckets = get(buckets_by_kind, kind, nothing)
        (buckets === nothing || isempty(buckets)) && continue
        record[String(kind)] = Dict{String,Any}(
            bucket => sort!([id for (id, b) in buckets if b == bucket])
            for bucket in ("enroll", "query")
        )
    end
    return record
end

# Sidecar `students` entry → `kind => (id => bucket)`.
function _sidecar_student_buckets(previous_split, label::AbstractString)
    out = Dict{Symbol,Dict{String,String}}()
    isa(previous_split, AbstractDict) || return out
    student = get(previous_split, label, nothing)
    isa(student, AbstractDict) || return out
    for kind in NAME_IMAGE_KINDS
        by_bucket = get(student, String(kind), nothing)
        isa(by_bucket, AbstractDict) || continue
        buckets = Dict{String,String}()
        for bucket in ("enroll", "query")
            ids = get(by_bucket, bucket, nothing)
            isa(ids, AbstractVector) || continue
            for id in ids
                buckets[String(id)] = bucket
            end
        end
        isempty(buckets) || (out[kind] = buckets)
    end
    return out
end

"""
    read_training_sidecar(path)

Return a training sidecar's contents, or `nothing` when it is missing or
unreadable. `sidecar["students"]` is what `split_name_handwriting` wants for
`previous_split`.
"""
function read_training_sidecar(path::AbstractString)::Union{Nothing,Dict{String,Any}}
    isfile(path) || return nothing
    data = try
        JSON.parsefile(String(path))
    catch
        return nothing
    end
    isa(data, AbstractDict) || return nothing
    return Dict{String,Any}(String(k) => v for (k, v) in data)
end

function write_training_sidecar(path::AbstractString, data::AbstractDict)
    mkpath(dirname(abspath(String(path))))
    open(String(path), "w") do io
        JSON.print(io, data, 2)
    end
    return String(path)
end

function _kind_counts(dataset)::Dict{Symbol,Int}
    counts = Dict{Symbol,Int}(kind => 0 for kind in NAME_IMAGE_KINDS)
    isnothing(dataset) && return counts
    for kind in dataset.kinds
        counts[kind] = get(counts, kind, 0) + 1
    end
    return counts
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
        composed = if dataset.kinds[source_index] === :assn
            compose_assignment_training_image(
                dataset.images[source_index];
                target_size=dataset.image_size,
                rng,
                kwargs...,
            )
        else
            compose_name_training_image(
                dataset.images[source_index],
                backgrounds[rand(rng, eachindex(backgrounds))];
                target_size=dataset.image_size,
                rng,
                kwargs...,
            )
        end
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
        source_path = grouped[label][rand(rng, eachindex(grouped[label]))]
        kind = name_image_kind(source_path)
        align = kind === :assn ? :center : :baseline
        source = fit_to_name_canvas(grayscale_float_image(load(source_path)), image_size; align)
        composed = if kind === :assn
            compose_assignment_training_image(source; target_size=image_size, rng, kwargs...)
        else
            bg = bgs[rand(rng, eachindex(bgs))]
            compose_name_training_image(source, bg; target_size=image_size, rng, kwargs...)
        end
        dest = joinpath(output_dir, string(name_image_prefix(kind), "preview_", lpad(string(i), 3, "0"), ".png"))
        save(dest, composed)
        push!(paths, dest)
    end
    return paths
end

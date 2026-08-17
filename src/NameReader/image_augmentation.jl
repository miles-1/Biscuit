using Colors
using FileIO
using Random
import YAML

"""
    AugmentedDatasetResult

Metadata returned by `save_augmented_dataset`.
"""
struct AugmentedDatasetResult
    output_directory::String
    train_paths::Dict{String,Vector{String}}
    test_paths::Dict{String,Vector{String}}
    source_split::Dict{String,Dict{String,Vector{String}}}
end

"""
    augment_image(image; kwargs...)

Create one randomly augmented, binary version of `image`.

The output is a `Matrix{Gray{Float32}}` where black pixels are `0` and white
pixels are `1`, which can be saved directly or converted for model training.

Keyword parameters:

- `blur_max_sigma=0.0`: maximum Gaussian blur sigma sampled uniformly from
  `0:blur_max_sigma`. Blur is only applied before thresholding non-bitmap input.
- `threshold_bounds=(0.4, 0.6)`: threshold range sampled uniformly. This may
  also be a function `image -> (lo, hi)` or a single numeric threshold.
- `rotation_max_degrees=0.0`: maximum absolute rotation angle.
- `translation_max_percent=0.0`: maximum shift as a fraction of image size. A
  value greater than `1` is interpreted as a percentage, so `5` means `5%`.
- `shear_max_degrees=(0.0, 0.0)`: maximum horizontal and vertical shear angles.
  A scalar applies to both axes.
- `noise_max_spatial_sigma=0.0`: maximum spatial correlation radius for noise
  in pixels. Zero gives independent salt-and-pepper flips; larger values cluster
  flips. A value is sampled uniformly from zero to this maximum for each image.
- `noise_max_percent=0.0`: maximum fraction of pixels to flip. A value greater
  than `1` is interpreted as a percentage. A value is sampled uniformly from
  zero to this maximum for each image.
- `line_noise_max_percent=0.0`: maximum fraction of pixels to flip in a separate
  noisy image that is composited only through random crossing-line masks.
- `line_noise_max_spatial_sigma=0.0`: maximum spatial correlation radius for
  the line-noise image.
- `line_noise_max_count=3`: maximum number of crossing lines when line noise is
  enabled.
- `line_noise_max_stroke_percent=0.03`: maximum line width as a fraction of the
  larger image dimension. A value greater than `1` is interpreted as a percent.
  Each line is straight or a quadratic Bezier curve with equal probability.
"""
function augment_image(
    image;
    blur_max_sigma::Real=0.0,
    threshold_bounds = (0.4, 0.6),
    rotation_max_degrees::Real = 0.0,
    translation_max_percent = 0.0,
    shear_max_degrees = (0.0, 0.0),
    noise_max_spatial_sigma::Real = 0.0,
    noise_max_percent::Real = 0.0,
    line_noise_max_spatial_sigma::Real = 0.0,
    line_noise_max_percent::Real = 0.0,
    line_noise_max_count::Integer = 3,
    line_noise_max_stroke_percent::Real = 0.03,
    rng::AbstractRNG=Random.default_rng(),
)
    gray = grayscale_float_image(image)
    bitmap = is_bitmap_image(gray)

    if bitmap
        black_mask = gray .< 0.5
    else
        sigma = random_uniform(rng, 0.0, max(0.0, Float64(blur_max_sigma)))
        blurred = sigma > 0 ? gaussian_blur(gray, sigma) : gray
        threshold = sample_threshold(rng, threshold_bounds, image)
        black_mask = blurred .< threshold
    end

    return augment_black_mask(
        black_mask;
        rotation_max_degrees,
        translation_max_percent,
        shear_max_degrees,
        noise_max_spatial_sigma,
        noise_max_percent,
        line_noise_max_spatial_sigma,
        line_noise_max_percent,
        line_noise_max_count,
        line_noise_max_stroke_percent,
        rng,
    )
end

function augment_black_mask(
    black_mask;
    rotation_max_degrees::Real = 0.0,
    translation_max_percent = 0.0,
    shear_max_degrees = (0.0, 0.0),
    noise_max_spatial_sigma::Real = 0.0,
    noise_max_percent::Real = 0.0,
    line_noise_max_spatial_sigma::Real = 0.0,
    line_noise_max_percent::Real = 0.0,
    line_noise_max_count::Integer = 3,
    line_noise_max_stroke_percent::Real = 0.03,
    rng::AbstractRNG=Random.default_rng(),
    kwargs...,
)
    augmented = apply_random_affine(
        black_mask;
        rotation_max_degrees,
        translation_max_percent,
        shear_max_degrees,
        rng,
    )

    augmented = apply_flip_noise(
        augmented;
        noise_max_spatial_sigma,
        noise_max_percent,
        rng,
    )

    augmented = apply_line_noise(
        augmented;
        line_noise_max_spatial_sigma,
        line_noise_max_percent,
        line_noise_max_count,
        line_noise_max_stroke_percent,
        rng,
    )

    return render_bitmap(augmented)
end

"""
    augment_image_file(path; kwargs...)

Load `path` and return one augmented image.
"""
augment_image_file(path::AbstractString; kwargs...) = augment_image(load(path); kwargs...)

"""
    preview_augmentations(image; n=16, kwargs...)

Return `n` independently augmented versions of `image`.
"""
function preview_augmentations(image; n::Integer=16, kwargs...)
    n >= 0 || throw(ArgumentError("n must be non-negative"))
    return [augment_image(image; kwargs...) for _ in 1:n]
end

"""
    save_preview_batch(image, output_dir; n=16, prefix="preview", kwargs...)

Generate and save `n` augmented preview images into `output_dir`.
Returns the written file paths.
"""
function save_preview_batch(
    image,
    output_dir::AbstractString;
    n::Integer=16,
    prefix::AbstractString="preview",
    kwargs...,
)
    assert_missing_or_empty_dir(output_dir)
    mkpath(output_dir)
    images = preview_augmentations(image; n, kwargs...)
    paths = String[]

    for (index, augmented) in enumerate(images)
        path = joinpath(output_dir, string(prefix, "-", lpad(string(index), 3, "0"), ".png"))
        save(path, augmented)
        push!(paths, path)
    end

    return paths
end

"""
    save_augmented_dataset(result; output_dir=nothing, n_per_image=8, train_percent=0.8, kwargs...)
    save_augmented_dataset(labeling_output_dir; output_dir=nothing, n_per_image=8, train_percent=0.8, kwargs...)

Create an augmented train/test dataset from a labeled `SplitGridResult` or from
a previous labeling output directory.

The split is stratified by label and is performed on the original tile paths
before augmentation. This avoids putting augmented versions of the same source
tile in both training and testing data.

If `output_dir` is not provided, it is generated from the original image path as
`preview_<original_image_name>_data_set`. For directory input, `labels.yaml` is
used when available; otherwise the directory name is used.

Augmented images are saved as:

```text
output_dir/
  train/<label>/<label>-001.png
  test/<label>/<label>-001.png
```

Use `n_per_image` to control how many augmented variants are generated from
each source tile. Augmentation keyword arguments are forwarded to
`augment_image`.
"""
function save_augmented_dataset(
    result::SplitGridResult;
    output_dir::Union{Nothing,AbstractString}=nothing,
    n_per_image::Integer=8,
    train_percent::Real=0.8,
    rng::AbstractRNG=Random.default_rng(),
    kwargs...,
)
    n_per_image >= 0 || throw(ArgumentError("n_per_image must be non-negative"))
    train_fraction = clamp(normalize_percent(train_percent), 0.0, 1.0)
    grouped_paths = group_tile_paths_by_label(result)
    isempty(grouped_paths) && throw(ArgumentError("SplitGridResult does not contain labeled tile paths"))
    dataset_dir = isnothing(output_dir) ? default_augmented_dataset_dir(result) : String(output_dir)

    return save_augmented_dataset_from_groups(
        grouped_paths,
        dataset_dir;
        n_per_image,
        train_fraction,
        rng,
        kwargs...,
    )
end

function save_augmented_dataset(
    labeling_output_dir::AbstractString;
    output_dir::Union{Nothing,AbstractString}=nothing,
    n_per_image::Integer=8,
    train_percent::Real=0.8,
    rng::AbstractRNG=Random.default_rng(),
    kwargs...,
)
    n_per_image >= 0 || throw(ArgumentError("n_per_image must be non-negative"))
    isdir(labeling_output_dir) || throw(ArgumentError("labeling_output_dir must be a directory"))

    train_fraction = clamp(normalize_percent(train_percent), 0.0, 1.0)
    grouped_paths, original_image_path = group_tile_paths_by_label_dir(labeling_output_dir)
    isempty(grouped_paths) && throw(ArgumentError("No labeled PNG files found in labeling_output_dir"))
    dataset_dir = isnothing(output_dir) ?
        default_augmented_dataset_dir(labeling_output_dir, original_image_path) :
        String(output_dir)

    return save_augmented_dataset_from_groups(
        grouped_paths,
        dataset_dir;
        n_per_image,
        train_fraction,
        rng,
        kwargs...,
    )
end

function save_augmented_dataset_from_groups(
    grouped_paths::Dict{String,Vector{String}},
    dataset_dir::AbstractString;
    n_per_image::Integer,
    train_fraction::Real,
    rng::AbstractRNG,
    kwargs...,
)
    reject_pending_paths!(grouped_paths)
    assert_missing_or_empty_dir(dataset_dir)

    train_paths = Dict{String,Vector{String}}()
    test_paths = Dict{String,Vector{String}}()
    source_split = Dict{String,Dict{String,Vector{String}}}()

    for label in sort(collect(keys(grouped_paths)))
        paths = shuffle(rng, grouped_paths[label])
        train_count = train_source_count(length(paths), train_fraction)
        train_sources = paths[1:train_count]
        test_sources = paths[(train_count + 1):end]

        source_split[label] = Dict(
            "train" => copy(train_sources),
            "test" => copy(test_sources),
        )

        train_paths[label] = save_augmented_sources(
            train_sources,
            joinpath(dataset_dir, "train", label),
            label;
            n_per_image,
            rng,
            kwargs...,
        )

        test_paths[label] = save_augmented_sources(
            test_sources,
            joinpath(dataset_dir, "test", label),
            label;
            n_per_image,
            rng,
            kwargs...,
        )
    end

    return AugmentedDatasetResult(String(dataset_dir), train_paths, test_paths, source_split)
end

function assert_missing_or_empty_dir(dir::AbstractString)
    if isdir(dir) && !isempty(readdir(dir))
        throw(ArgumentError("refusing to write into non-empty directory: $(dir)"))
    end
end

save_augmented_dataset(
    result::SplitGridResult,
    output_dir::AbstractString;
    kwargs...,
) = save_augmented_dataset(result; output_dir=output_dir, kwargs...)

function default_augmented_dataset_dir(result::SplitGridResult)
    image_dir = dirname(result.image_path)
    base = splitext(basename(result.image_path))[1]
    return joinpath(image_dir, "preview_" * base * "_data_set")
end

function default_augmented_dataset_dir(labeling_output_dir::AbstractString, original_image_path)
    base = if isnothing(original_image_path) || isempty(String(original_image_path))
        basename(labeling_output_dir)
    else
        splitext(basename(String(original_image_path)))[1]
    end

    return joinpath(dirname(labeling_output_dir), "preview_" * base * "_data_set")
end

function train_source_count(total::Integer, train_fraction::Real)
    total == 0 && return 0
    total == 1 && return 1

    count = round(Int, Float64(train_fraction) * total)
    return clamp(count, 1, total - 1)
end

function group_tile_paths_by_label(result::SplitGridResult)
    grouped = Dict{String,Vector{String}}()

    for path in result.tile_paths
        is_pending_path(path) && throw(ArgumentError("pending image cannot be used as labeled data: $(path)"))
        label = label_from_tile_path(path)
        isnothing(label) && continue
        push!(get!(grouped, label, String[]), path)
    end

    return grouped
end

function group_tile_paths_by_label_dir(labeling_output_dir::AbstractString)
    sidecar_path = joinpath(labeling_output_dir, "labels.yaml")
    if isfile(sidecar_path)
        grouped, original_image_path = group_tile_paths_from_sidecar(labeling_output_dir, sidecar_path)
        if !isempty(grouped)
            return grouped, original_image_path
        end
    end

    grouped = group_tile_paths_from_filenames(labeling_output_dir)
    isempty(grouped) || return grouped, nothing

    return group_tile_paths_from_label_subdirs(labeling_output_dir), nothing
end

function group_tile_paths_from_sidecar(labeling_output_dir::AbstractString, sidecar_path::AbstractString)
    data = YAML.load_file(sidecar_path)
    original_image_path = yaml_get(data, "image", nothing)
    records = yaml_get(data, "records", [])
    grouped = Dict{String,Vector{String}}()

    for record in records
        label = yaml_get(record, "label", nothing)
        file = yaml_get(record, "file", nothing)
        (isnothing(label) || isnothing(file)) && continue

        path = joinpath(labeling_output_dir, String(file))
        is_pending_path(path) && throw(ArgumentError("pending image cannot be used as labeled data: $(path)"))
        isfile(path) || continue
        push!(get!(grouped, String(label), String[]), path)
    end

    return grouped, original_image_path
end

function group_tile_paths_from_filenames(labeling_output_dir::AbstractString)
    grouped = Dict{String,Vector{String}}()

    for name in readdir(labeling_output_dir)
        path = joinpath(labeling_output_dir, name)
        isfile(path) || continue
        lowercase(splitext(name)[2]) == ".png" || continue
        is_pending_path(path) && throw(ArgumentError("pending image cannot be used as labeled data: $(path)"))

        label = label_from_filename(name)
        isnothing(label) && continue
        push!(get!(grouped, label, String[]), path)
    end

    return grouped
end

"""
    group_tile_paths_from_label_subdirs(root)

Treat each immediate subdirectory of `root` as a label. This matches the
handwriting sample layout:

```text
root/
  lastname,firstname/
    01.png
    02.png
```
"""
function group_tile_paths_from_label_subdirs(root::AbstractString)
    grouped = Dict{String,Vector{String}}()

    for name in sort(readdir(root))
        dir = joinpath(root, name)
        isdir(dir) || continue
        startswith(name, ".") && continue

        paths = String[]
        for file in sort(readdir(dir))
            path = joinpath(dir, file)
            isfile(path) || continue
            lowercase(splitext(file)[2]) == ".png" || continue
            is_pending_path(path) && throw(ArgumentError("pending image cannot be used as labeled data: $(path)"))
            push!(paths, path)
        end

        isempty(paths) && continue
        grouped[name] = paths
    end

    return grouped
end

function yaml_get(data, key::AbstractString, default)
    if data isa AbstractDict
        return get(data, key, get(data, Symbol(key), default))
    end

    return default
end

function reject_pending_paths!(grouped_paths::Dict{String,Vector{String}})
    for paths in values(grouped_paths)
        for path in paths
            is_pending_path(path) && throw(ArgumentError("pending image cannot be used as labeled data: $(path)"))
        end
    end
end

function is_pending_path(path::AbstractString)
    return startswith(basename(path), "_pending")
end

function label_from_filename(name::AbstractString)
    stem = splitext(basename(name))[1]
    matched = match(r"^(.+)-\d+$", stem)
    return isnothing(matched) ? nothing : matched.captures[1]
end

"""
    label_from_tile_path(path)

Return the label encoded in `path`. Prefers the `label-001.png` filename
convention; otherwise uses the parent directory name, which is the layout of
`practice/EvolutionFa26_name_training_data`.
"""
function label_from_tile_path(path::AbstractString)
    from_name = label_from_filename(path)
    isnothing(from_name) || return from_name
    parent = basename(dirname(path))
    return isempty(parent) || parent in (".", "/") ? nothing : parent
end

function save_augmented_sources(
    source_paths,
    output_dir::AbstractString,
    label::AbstractString;
    n_per_image::Integer,
    rng::AbstractRNG,
    kwargs...,
)
    mkpath(output_dir)
    saved_paths = String[]
    output_index = 1

    for source_path in source_paths
        source = load(source_path)
        source_mask = bitmap_black_mask(source)
        for _ in 1:n_per_image
            augmented = isnothing(source_mask) ?
                augment_image(source; rng, kwargs...) :
                augment_black_mask(source_mask; rng, kwargs...)
            output_path = joinpath(output_dir, string(label, "-", lpad(string(output_index), 4, "0"), ".png"))
            save(output_path, augmented)
            push!(saved_paths, output_path)
            output_index += 1
        end
    end

    return saved_paths
end

function bitmap_black_mask(image)
    gray = grayscale_float_image(image)
    is_bitmap_image(gray) || return nothing
    return gray .< 0.5
end

function grayscale_float_image(image)
    return map(image) do pixel
        if pixel isa Number
            return clamp(Float64(pixel), 0.0, 1.0)
        end

        return clamp(Float64(Gray(pixel)), 0.0, 1.0)
    end
end

function is_bitmap_image(gray; atol=1e-6)
    return all(value -> value <= atol || value >= 1 - atol, gray)
end

function render_bitmap(black_mask)
    return map(black_mask) do is_black
        Gray{Float32}(is_black ? 0.0f0 : 1.0f0)
    end
end

function random_uniform(rng::AbstractRNG, lo::Real, hi::Real)
    lo <= hi || throw(ArgumentError("lower bound must be <= upper bound"))
    return Float64(lo) + rand(rng) * (Float64(hi) - Float64(lo))
end

function sample_threshold(rng::AbstractRNG, threshold_bounds, image)
    bounds = threshold_bounds isa Function ? threshold_bounds(image) : threshold_bounds

    if bounds isa Number
        return clamp(Float64(bounds), 0.0, 1.0)
    end

    lo, hi = bounds
    return clamp(random_uniform(rng, lo, hi), 0.0, 1.0)
end

function normalize_percent(value::Real)
    percent = abs(Float64(value))
    return percent > 1.0 ? percent / 100.0 : percent
end

function normalize_percent_pair(value)
    if value isa Number
        percent = normalize_percent(value)
        return percent, percent
    end

    first_percent, second_percent = value
    return normalize_percent(first_percent), normalize_percent(second_percent)
end

function gaussian_kernel(sigma::Real)
    sigma = Float64(sigma)
    sigma > 0 || return [1.0]

    radius = max(1, ceil(Int, 3 * sigma))
    values = [exp(-(offset^2) / (2 * sigma^2)) for offset in -radius:radius]
    return values ./ sum(values)
end

function gaussian_blur(image, sigma::Real)
    kernel = gaussian_kernel(sigma)
    radius = length(kernel) ÷ 2
    height, width = size(image)

    horizontal = similar(image, Float64)
    for row in 1:height
        for col in 1:width
            value = 0.0
            for (kernel_index, weight) in enumerate(kernel)
                offset = kernel_index - radius - 1
                source_col = clamp(col + offset, 1, width)
                value += weight * image[row, source_col]
            end
            horizontal[row, col] = value
        end
    end

    blurred = similar(image, Float64)
    for row in 1:height
        for col in 1:width
            value = 0.0
            for (kernel_index, weight) in enumerate(kernel)
                offset = kernel_index - radius - 1
                source_row = clamp(row + offset, 1, height)
                value += weight * horizontal[source_row, col]
            end
            blurred[row, col] = value
        end
    end

    return blurred
end

function sample_shear_angles(rng::AbstractRNG, shear_max_degrees)
    if shear_max_degrees isa Number
        max_horizontal = max_vertical = abs(Float64(shear_max_degrees))
    else
        max_horizontal, max_vertical = shear_max_degrees
        max_horizontal = abs(Float64(max_horizontal))
        max_vertical = abs(Float64(max_vertical))
    end

    horizontal = random_uniform(rng, -max_horizontal, max_horizontal)
    vertical = random_uniform(rng, -max_vertical, max_vertical)
    return deg2rad(horizontal), deg2rad(vertical)
end

function apply_random_affine(
    black_mask;
    rotation_max_degrees::Real,
    translation_max_percent,
    shear_max_degrees,
    rng::AbstractRNG,
)
    if abs(rotation_max_degrees) <= eps(Float64) &&
       all(iszero, normalize_percent_pair(translation_max_percent)) &&
       shear_is_zero(shear_max_degrees)
        return black_mask
    end

    height, width = size(black_mask)
    rotation = deg2rad(random_uniform(rng, -abs(rotation_max_degrees), abs(rotation_max_degrees)))
    horizontal_shear_angle, vertical_shear_angle = sample_shear_angles(rng, shear_max_degrees)
    translation_y_percent, translation_x_percent = normalize_percent_pair(translation_max_percent)
    shift_y = random_uniform(rng, -translation_y_percent * height, translation_y_percent * height)
    shift_x = random_uniform(rng, -translation_x_percent * width, translation_x_percent * width)

    cos_theta = cos(rotation)
    sin_theta = sin(rotation)
    shx = tan(horizontal_shear_angle)
    shy = tan(vertical_shear_angle)

    # Forward transform: shear * rotation. Sampling uses the inverse transform.
    a = cos_theta + shx * sin_theta
    b = -sin_theta + shx * cos_theta
    c = shy * cos_theta + sin_theta
    d = -shy * sin_theta + cos_theta
    det = a * d - b * c
    abs(det) > eps(Float64) || throw(ArgumentError("shear/rotation produced a singular transform"))

    center_y = (height + 1) / 2
    center_x = (width + 1) / 2
    transformed = falses(height, width)

    for row in 1:height
        for col in 1:width
            dest_x = col - center_x - shift_x
            dest_y = row - center_y - shift_y

            source_x = (d * dest_x - b * dest_y) / det + center_x
            source_y = (-c * dest_x + a * dest_y) / det + center_y
            source_col = round(Int, source_x)
            source_row = round(Int, source_y)

            if 1 <= source_row <= height && 1 <= source_col <= width
                transformed[row, col] = black_mask[source_row, source_col]
            end
        end
    end

    return transformed
end

function shear_is_zero(shear_max_degrees)
    if shear_max_degrees isa Number
        return abs(Float64(shear_max_degrees)) <= eps(Float64)
    end

    horizontal, vertical = shear_max_degrees
    return abs(Float64(horizontal)) <= eps(Float64) && abs(Float64(vertical)) <= eps(Float64)
end

function apply_flip_noise(
    black_mask;
    noise_max_spatial_sigma::Real,
    noise_max_percent::Real,
    rng::AbstractRNG,
)
    percent = random_uniform(rng, 0.0, clamp(normalize_percent(noise_max_percent), 0.0, 1.0))
    spatial_sigma = random_uniform(rng, 0.0, max(0.0, Float64(noise_max_spatial_sigma)))
    total_pixels = length(black_mask)
    flip_count = round(Int, percent * total_pixels)
    flip_count == 0 && return black_mask

    noisy = copy(black_mask)
    if spatial_sigma <= 0
        for linear_index in randperm(rng, total_pixels)[1:flip_count]
            noisy[linear_index] = !noisy[linear_index]
        end
        return noisy
    end

    field = rand(rng, Float64, size(black_mask))
    field = gaussian_blur(field, spatial_sigma)

    ordered_indices = sortperm(vec(field); rev=true)
    for linear_index in ordered_indices[1:flip_count]
        noisy[linear_index] = !noisy[linear_index]
    end

    return noisy
end

function apply_line_noise(
    black_mask;
    line_noise_max_spatial_sigma::Real,
    line_noise_max_percent::Real,
    line_noise_max_count::Integer,
    line_noise_max_stroke_percent::Real,
    rng::AbstractRNG,
)
    max_percent = clamp(normalize_percent(line_noise_max_percent), 0.0, 1.0)
    max_percent == 0 && return black_mask
    line_noise_max_count <= 0 && return black_mask
    max_stroke_width = line_noise_max_stroke_width(size(black_mask), line_noise_max_stroke_percent)
    max_stroke_width <= 0 && return black_mask

    noisy = apply_flip_noise(
        black_mask;
        noise_max_spatial_sigma=line_noise_max_spatial_sigma,
        noise_max_percent=line_noise_max_percent,
        rng,
    )
    line_mask = random_crossing_line_mask(
        size(black_mask);
        max_count=line_noise_max_count,
        max_stroke_width,
        rng,
    )

    combined = copy(black_mask)
    combined[line_mask] .= noisy[line_mask]
    return combined
end

function random_crossing_line_mask(
    image_size;
    max_count::Integer,
    max_stroke_width::Integer,
    rng::AbstractRNG,
)
    height, width = image_size
    line_count = rand(rng, 1:max_count)
    mask = falses(height, width)

    for _ in 1:line_count
        angle = random_uniform(rng, 0.0, pi)
        min_offset, max_offset = line_offset_bounds(height, width, angle)
        offset = random_uniform(rng, min_offset, max_offset)
        stroke_width = rand(rng, 1:max_stroke_width)
        if rand(rng, Bool)
            draw_infinite_line!(mask, angle, offset, stroke_width)
        else
            draw_bezier_curve!(mask, stroke_width, rng)
        end
    end

    return mask
end

function line_noise_max_stroke_width(image_size, line_noise_max_stroke_percent::Real)
    height, width = image_size
    stroke_percent = normalize_percent(line_noise_max_stroke_percent)
    return floor(Int, max(0.0, stroke_percent) * max(height, width))
end

function line_offset_bounds(height::Integer, width::Integer, angle::Real)
    center_y = (height + 1) / 2
    center_x = (width + 1) / 2
    normal_x = cos(angle)
    normal_y = sin(angle)
    corners = (
        (1 - center_x, 1 - center_y),
        (width - center_x, 1 - center_y),
        (1 - center_x, height - center_y),
        (width - center_x, height - center_y),
    )
    offsets = [x * normal_x + y * normal_y for (x, y) in corners]
    return minimum(offsets), maximum(offsets)
end

function draw_infinite_line!(mask, angle::Real, offset::Real, line_width::Integer)
    height, width = size(mask)
    center_y = (height + 1) / 2
    center_x = (width + 1) / 2
    normal_x = cos(angle)
    normal_y = sin(angle)
    direction_x = -normal_y
    direction_y = normal_x
    extent = hypot(height, width)
    start_point = (
        center_x + offset * normal_x - extent * direction_x,
        center_y + offset * normal_y - extent * direction_y,
    )
    end_point = (
        center_x + offset * normal_x + extent * direction_x,
        center_y + offset * normal_y + extent * direction_y,
    )
    steps = max(8, ceil(Int, 2 * extent))

    for step in 0:steps
        t = step / steps
        x = (1 - t) * start_point[1] + t * end_point[1]
        y = (1 - t) * start_point[2] + t * end_point[2]
        stamp_disk!(mask, (x, y), line_width)
    end

    return mask
end

function draw_bezier_curve!(mask, line_width::Integer, rng::AbstractRNG)
    height, width = size(mask)
    start_point = random_boundary_point(height, width, rng)
    end_point = random_boundary_point(height, width, rng)
    control_point = (
        random_uniform(rng, -0.25 * width, 1.25 * width),
        random_uniform(rng, -0.25 * height, 1.25 * height),
    )
    steps = max(8, ceil(Int, 2 * hypot(height, width)))

    for step in 0:steps
        t = step / steps
        current = quadratic_bezier_point(start_point, control_point, end_point, t)
        stamp_disk!(mask, current, line_width)
    end

    return mask
end

function random_boundary_point(height::Integer, width::Integer, rng::AbstractRNG)
    side = rand(rng, 1:4)
    if side == 1
        return (random_uniform(rng, 1, width), 1.0)
    elseif side == 2
        return (random_uniform(rng, 1, width), Float64(height))
    elseif side == 3
        return (1.0, random_uniform(rng, 1, height))
    else
        return (Float64(width), random_uniform(rng, 1, height))
    end
end

function quadratic_bezier_point(start_point, control_point, end_point, t::Real)
    x0, y0 = start_point
    x1, y1 = control_point
    x2, y2 = end_point
    u = 1 - t
    x = u^2 * x0 + 2 * u * t * x1 + t^2 * x2
    y = u^2 * y0 + 2 * u * t * y1 + t^2 * y2
    return x, y
end

function stamp_disk!(mask, center_point, line_width::Integer)
    height, width = size(mask)
    center_x, center_y = center_point
    radius = max(0.5, line_width / 2)
    row_min = max(1, floor(Int, center_y - radius))
    row_max = min(height, ceil(Int, center_y + radius))
    col_min = max(1, floor(Int, center_x - radius))
    col_max = min(width, ceil(Int, center_x + radius))
    radius_squared = radius^2

    for row in row_min:row_max
        dy = row - center_y
        for col in col_min:col_max
            dx = col - center_x
            if dx^2 + dy^2 <= radius_squared
                mask[row, col] = true
            end
        end
    end

    return mask
end

using Colors
using FileIO
using Random

"""
Target canvas for name-field images, matching Typst's 200pt x 55pt crop at 2.75x
(writing area, printed line 13pt above the bottom, room for descenders).
Layout is `(height, width)`.
"""
const NAME_FIELD_HEIGHT = 151
const NAME_FIELD_WIDTH = 550
const NAME_FIELD_SIZE = (NAME_FIELD_HEIGHT, NAME_FIELD_WIDTH)
# Line is `place(bottom+left, dy: -13pt)` in a 55pt-tall box.
const NAME_FIELD_BASELINE_FRAC = (55 - 13) / 55

"""
Default directory for scanned blank name fields / assignment pages.
"""
background_training_dir() = joinpath(@__DIR__, "background_training_images")

"""
    prepare_name_image(image; threshold=0.5, morphology_radius=1, isolated_pixel_radius=1)

Shared train/infer cleanup: threshold to black-and-white, drop isolated specks,
dilate then erode, then topologically thin. Returns a `Matrix{Gray{Float32}}`
(black skeleton on white).
"""
function prepare_name_image(
    image;
    threshold::Real=0.5,
    morphology_radius::Integer=1,
    isolated_pixel_radius::Integer=1,
)
    return thin_image(
        image;
        threshold,
        morphology_radius,
        isolated_pixel_radius,
    )
end

"""
    compose_name_training_image(handwriting, background; kwargs...)

Build one training sample as described in the NameReader plan:

1. Slightly rotate/shear/shift `handwriting` only (background stays put).
2. Overlay with `min(paper, handwriting)` (darker ink wins; the printed baseline stays).
3. Sprinkle a random amount of pure-black dots.
4. Threshold to black-and-white (biased toward keeping faded ink).
5. Dilate, erode, then thin.

Handwriting crops (the 40pt training boxes) are smaller than the 55pt name
field. They are centered horizontally, and the ink is sat on the printed
baseline so names look written on the line rather than floating in the
top-left. Small random shifts are applied after that.
"""
function compose_name_training_image(
    handwriting,
    background;
    target_size::Tuple{Int,Int}=NAME_FIELD_SIZE,
    rotation_max_degrees::Real=1.5,
    translation_max_percent=0.0,
    translation_max_pixels=(10, 50),
    shear_max_degrees=1.0,
    noise_max_percent::Real=0.012,
    threshold_bounds=(0.62, 0.82),
    morphology_radius::Integer=1,
    isolated_pixel_radius::Integer=1,
    rng::AbstractRNG=Random.default_rng(),
)
    hand = fit_to_name_canvas(grayscale_float_image(handwriting), target_size; align=:baseline)
    bg = fit_to_name_canvas(grayscale_float_image(background), target_size; align=:center)

    hand = apply_random_affine_gray(
        hand;
        rotation_max_degrees,
        translation_max_percent,
        translation_max_pixels,
        shear_max_degrees,
        rng,
        interpolate=false,
    )

    overlay = min.(hand, bg)
    overlay = apply_black_dot_noise(overlay; noise_max_percent, rng)
    threshold = sample_threshold(rng, threshold_bounds, overlay)
    bitmap = overlay .< threshold
    return thin_image_from_mask(
        bitmap;
        morphology_radius,
        isolated_pixel_radius,
    )
end

function thin_image_from_mask(
    foreground::AbstractMatrix{Bool};
    morphology_radius::Integer=1,
    isolated_pixel_radius::Integer=1,
)
    cleaned = remove_isolated_foreground(foreground; radius=isolated_pixel_radius)
    cleaned = close_foreground(cleaned; radius=morphology_radius)
    thinned = thinning(cleaned)
    return map(thinned) do is_foreground
        Gray{Float32}(is_foreground ? 0.0f0 : 1.0f0)
    end
end

"""
    load_background_images(dir; target_size=NAME_FIELD_SIZE)

Load PNG/JPEG/TIFF backgrounds. Full letter-size pages are cropped to the
top-right name field. If `dir` has no images, return one synthetic baseline.
"""
function load_background_images(
    dir::AbstractString=background_training_dir();
    target_size::Tuple{Int,Int}=NAME_FIELD_SIZE,
)
    paths = background_image_paths(dir)
    if isempty(paths)
        println("No background scans in $(dir); using a synthetic name-line baseline.")
        return [synthetic_name_field_background(target_size)]
    end

    images = Matrix{Float32}[]
    for path in paths
        gray = grayscale_float_image(load(path))
        field = crop_background_name_field(gray)
        push!(images, fit_to_name_canvas(field, target_size; align=:center))
    end
    println("Loaded $(length(images)) background scan(s) from $(dir)")
    flush(stdout)
    return images
end

function background_image_paths(dir::AbstractString)
    isdir(dir) || return String[]
    paths = String[]
    allowed = Set(DEFAULT_IMAGE_EXTENSIONS)
    for (root, _, files) in walkdir(dir)
        for name in files
            lowercase(splitext(name)[2]) in allowed || continue
            push!(paths, joinpath(root, name))
        end
    end
    return sort(paths)
end

"""
If the image looks like a full letter page, crop the top-right name field using
the Typst layout (200pt x 55pt near the page's top-right on 612 x 792).
"""
function crop_background_name_field(gray::AbstractMatrix)
    height, width = size(gray)
    looks_like_page = height >= 400 && width >= 300 && height / width > 1.15
    looks_like_page || return gray

    # Generous top-right crop covering the 200x60pt field (plus place() offsets).
    x0 = clamp(round(Int, (1 - 240 / 612) * width) + 1, 1, width)
    y0 = 1
    x1 = width
    y1 = clamp(round(Int, (100 / 792) * height), 1, height)
    return gray[y0:y1, x0:x1]
end

function synthetic_name_field_background(target_size::Tuple{Int,Int}=NAME_FIELD_SIZE)
    height, width = target_size
    bg = fill(1.0f0, height, width)
    baseline = clamp(round(Int, NAME_FIELD_BASELINE_FRAC * height), 1, height)
    bg[baseline, :] .= 0.0f0
    if baseline > 1
        bg[baseline - 1, :] .= 0.35f0
    end
    return bg
end

function fit_to_name_canvas(
    gray::AbstractMatrix,
    target_size::Tuple{Int,Int};
    align::Symbol=:bottom,
    pad_value::Float32=1.0f0,
)
    target_height, target_width = target_size
    height, width = size(gray)
    canvas = fill(pad_value, target_height, target_width)

    scale = min(target_height / height, target_width / width)
    new_h = max(1, round(Int, height * scale))
    new_w = max(1, round(Int, width * scale))
    resized = (new_h == height && new_w == width) ? gray : nearest_resize(gray, (new_h, new_w))

    left = div(target_width - new_w, 2)
    top = handwriting_canvas_top(resized, target_height, new_h, align)
    paste_into_canvas!(canvas, resized; top, left)
    return canvas
end

function handwriting_canvas_top(resized, target_height::Int, new_h::Int, align::Symbol)
    align === :bottom && return target_height - new_h
    align === :center && return div(target_height - new_h, 2)
    align === :top && return 0
    align === :baseline || throw(ArgumentError("unknown name-canvas align: $(repr(align))"))

    ink = vec(any(resized .< 0.5f0; dims=2))
    ink_top = findfirst(ink)
    ink_bottom = findlast(ink)
    (ink_top === nothing || ink_bottom === nothing) && return div(target_height - new_h, 2)

    baseline = clamp(round(Int, NAME_FIELD_BASELINE_FRAC * target_height), 1, target_height)
    # 0-based paste offset so source row `ink_bottom` lands on the printed line.
    # Whitespace may hang off the canvas; ink is kept on-canvas when it fits.
    top = baseline - ink_bottom
    return clamp(top, 1 - ink_top, target_height - ink_bottom)
end

function paste_into_canvas!(canvas, src; top::Int, left::Int)
    canvas_h, canvas_w = size(canvas)
    src_h, src_w = size(src)
    src_r0 = max(1, 1 - top)
    src_c0 = max(1, 1 - left)
    dst_r0 = max(1, top + 1)
    dst_c0 = max(1, left + 1)
    src_r1 = min(src_h, canvas_h - top)
    src_c1 = min(src_w, canvas_w - left)
    (src_r1 < src_r0 || src_c1 < src_c0) && return canvas
    dst_r1 = dst_r0 + (src_r1 - src_r0)
    dst_c1 = dst_c0 + (src_c1 - src_c0)
    canvas[dst_r0:dst_r1, dst_c0:dst_c1] .= Float32.(src[src_r0:src_r1, src_c0:src_c1])
    return canvas
end

function apply_black_dot_noise(
    gray::AbstractMatrix;
    noise_max_percent::Real=0.012,
    rng::AbstractRNG=Random.default_rng(),
)
    percent = random_uniform(rng, 0.0, clamp(normalize_percent(noise_max_percent), 0.0, 1.0))
    flip_count = round(Int, percent * length(gray))
    flip_count == 0 && return gray

    noisy = copy(gray)
    for linear_index in randperm(rng, length(gray))[1:flip_count]
        noisy[linear_index] = 0
    end
    return noisy
end

function apply_random_affine_gray(
    gray::AbstractMatrix;
    rotation_max_degrees::Real,
    translation_max_percent=0.0,
    translation_max_pixels=nothing,
    shear_max_degrees,
    rng::AbstractRNG,
    fill_value::Float32=1.0f0,
    interpolate::Bool=true,
)
    pixels_zero = translation_max_pixels === nothing || all(iszero, translation_max_pixels)
    if abs(rotation_max_degrees) <= eps(Float64) &&
       all(iszero, normalize_percent_pair(translation_max_percent)) &&
       pixels_zero &&
       shear_is_zero(shear_max_degrees)
        return gray
    end

    height, width = size(gray)
    rotation = deg2rad(random_uniform(rng, -abs(rotation_max_degrees), abs(rotation_max_degrees)))
    horizontal_shear_angle, vertical_shear_angle = sample_shear_angles(rng, shear_max_degrees)
    if translation_max_pixels !== nothing
        max_dy, max_dx = Float64(translation_max_pixels[1]), Float64(translation_max_pixels[2])
        shift_y = random_uniform(rng, -abs(max_dy), abs(max_dy))
        shift_x = random_uniform(rng, -abs(max_dx), abs(max_dx))
    else
        translation_y_percent, translation_x_percent = normalize_percent_pair(translation_max_percent)
        shift_y = random_uniform(rng, -translation_y_percent * height, translation_y_percent * height)
        shift_x = random_uniform(rng, -translation_x_percent * width, translation_x_percent * width)
    end

    cos_theta = cos(rotation)
    sin_theta = sin(rotation)
    shx = tan(horizontal_shear_angle)
    shy = tan(vertical_shear_angle)

    a = cos_theta + shx * sin_theta
    b = -sin_theta + shx * cos_theta
    c = shy * cos_theta + sin_theta
    d = -shy * sin_theta + cos_theta
    det = a * d - b * c
    abs(det) > eps(Float64) || throw(ArgumentError("shear/rotation produced a singular transform"))

    center_y = (height + 1) / 2
    center_x = (width + 1) / 2
    transformed = fill(fill_value, height, width)

    for row in 1:height
        for col in 1:width
            dest_x = col - center_x - shift_x
            dest_y = row - center_y - shift_y
            source_x = (d * dest_x - b * dest_y) / det + center_x
            source_y = (-c * dest_x + a * dest_y) / det + center_y
            transformed[row, col] = interpolate ?
                sample_bilinear(gray, source_y, source_x, fill_value) :
                sample_nearest(gray, source_y, source_x, fill_value)
        end
    end

    return transformed
end

function sample_nearest(image::AbstractMatrix, y::Real, x::Real, fill_value)
    height, width = size(image)
    (y < 1 || x < 1 || y > height || x > width) && return fill_value
    return image[clamp(round(Int, y), 1, height), clamp(round(Int, x), 1, width)]
end

function sample_bilinear(image::AbstractMatrix, y::Real, x::Real, fill_value)
    height, width = size(image)
    (y < 1 || x < 1 || y > height || x > width) && return fill_value

    r0 = clamp(floor(Int, y), 1, height)
    c0 = clamp(floor(Int, x), 1, width)
    r1 = min(r0 + 1, height)
    c1 = min(c0 + 1, width)
    wy = y - r0
    wx = x - c0
    top = (1 - wx) * image[r0, c0] + wx * image[r0, c1]
    bottom = (1 - wx) * image[r1, c0] + wx * image[r1, c1]
    return (1 - wy) * top + wy * bottom
end

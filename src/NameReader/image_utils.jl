using Colors
using FileIO
import OpenCV as cv

const DEFAULT_IMAGE_EXTENSIONS = (".png", ".jpg", ".jpeg", ".bmp", ".tif", ".tiff")

"""
    max_image_dimensions(folder; recursive=true, extensions=DEFAULT_IMAGE_EXTENSIONS)

Return `(max_width, max_height)` across all image files in `folder`.
Subdirectories are included by default.
"""
function max_image_dimensions(
    folder::AbstractString;
    recursive::Bool=true,
    extensions=DEFAULT_IMAGE_EXTENSIONS,
)
    return max_image_dimensions(image_paths_in_folder(folder; recursive, extensions))
end

"""
    resize_images_with_padding(folder; target_dimensions=nothing, output_dir=nothing, recursive=true)

Pad every image in `folder` to the same dimensions without scaling or cropping.
By default, the target dimensions are the maximum width and height found in the
folder. Padding is split as evenly as possible across left/right and top/bottom.

If `output_dir` is `nothing`, images are overwritten in place. Otherwise, padded
images are written under `output_dir` while preserving relative subfolder paths.
Returns the paths that were written.
"""
function resize_images_with_padding(
    folder::AbstractString;
    target_dimensions::Union{Nothing,Tuple{Int,Int}}=nothing,
    output_dir::Union{Nothing,AbstractString}=nothing,
    recursive::Bool=true,
    extensions=DEFAULT_IMAGE_EXTENSIONS,
    padding_value=nothing,
)
    paths = image_paths_in_folder(folder; recursive, extensions)
    width, height = isnothing(target_dimensions) ? max_image_dimensions(paths) : target_dimensions
    width > 0 || throw(ArgumentError("target width must be positive"))
    height > 0 || throw(ArgumentError("target height must be positive"))

    written_paths = String[]
    for path in paths
        image = load(path)
        padded = pad_image_to_dimensions(image, (width, height); padding_value)
        output_path = isnothing(output_dir) ? path : joinpath(output_dir, relpath(path, folder))
        parent = dirname(output_path)
        if !isempty(parent)
            mkpath(parent)
        end
        save(output_path, padded)
        push!(written_paths, output_path)
    end

    return written_paths
end

"""
    thin_images_in_folder(folder; output_dir=nothing, recursive=true, threshold=0.5, morphology_radius=0, isolated_pixel_radius=0)

Apply ImageMorphology's topological thinning operation to every image in
`folder`. Dark pixels are treated as foreground by default, and the output is a
black skeleton on a white background. If `morphology_radius` is positive,
foreground dilation followed by erosion is applied before thinning.
If `isolated_pixel_radius` is positive, foreground pixels with no neighboring
foreground pixels within that radius are removed before morphology/thinning.

If `output_dir` is `nothing`, images are overwritten in place. Otherwise,
thinned images are written under `output_dir` while preserving relative
subfolder paths. Returns the paths that were written.
"""
function thin_images_in_folder(
    folder::AbstractString;
    output_dir::Union{Nothing,AbstractString}=nothing,
    recursive::Bool=true,
    extensions=DEFAULT_IMAGE_EXTENSIONS,
    threshold::Real=0.5,
    morphology_radius::Integer=0,
    isolated_pixel_radius::Integer=0,
)
    paths = image_paths_in_folder(folder; recursive, extensions)
    written_paths = String[]

    for path in paths
        image = load(path)
        thinned = thin_image(image; threshold, morphology_radius, isolated_pixel_radius)
        output_path = isnothing(output_dir) ? path : joinpath(output_dir, relpath(path, folder))
        parent = dirname(output_path)
        if !isempty(parent)
            mkpath(parent)
        end
        save(output_path, thinned)
        push!(written_paths, output_path)
    end

    return written_paths
end

function max_image_dimensions(paths::Vector{String})
    isempty(paths) && throw(ArgumentError("no image files found"))

    max_width = 0
    max_height = 0
    for path in paths
        image = load(path)
        height, width = size(image)[1:2]
        max_width = max(max_width, width)
        max_height = max(max_height, height)
    end

    return max_width, max_height
end

function image_paths_in_folder(
    folder::AbstractString;
    recursive::Bool=true,
    extensions=DEFAULT_IMAGE_EXTENSIONS,
)
    isdir(folder) || throw(ArgumentError("folder does not exist: $(folder)"))

    allowed_extensions = Set(lowercase.(extensions))
    paths = String[]

    if recursive
        for (root, dirs, files) in walkdir(folder)
            sort!(dirs)
            append_image_paths!(paths, root, files, allowed_extensions)
        end
    else
        append_image_paths!(paths, folder, readdir(folder), allowed_extensions)
    end

    isempty(paths) && throw(ArgumentError("no image files found in $(folder)"))
    return sort(paths)
end

function append_image_paths!(paths::Vector{String}, folder::AbstractString, names, allowed_extensions)
    for name in sort(collect(names))
        path = joinpath(folder, name)
        isfile(path) || continue
        lowercase(splitext(name)[2]) in allowed_extensions || continue
        push!(paths, path)
    end

    return paths
end

function pad_image_to_dimensions(image, target_dimensions::Tuple{Int,Int}; padding_value=nothing)
    target_width, target_height = target_dimensions
    height, width = size(image)[1:2]
    width <= target_width || throw(ArgumentError("image width $(width) exceeds target width $(target_width)"))
    height <= target_height || throw(ArgumentError("image height $(height) exceeds target height $(target_height)"))

    top = div(target_height - height, 2)
    left = div(target_width - width, 2)
    row_range = (top + 1):(top + height)
    col_range = (left + 1):(left + width)
    output_size = (target_height, target_width, size(image)[3:end]...)
    canvas = fill(padding_pixel(eltype(image), padding_value), output_size)
    canvas[row_range, col_range, ntuple(_ -> Colon(), ndims(image) - 2)...] .= image

    return canvas
end

function padding_pixel(::Type{T}, value) where {T}
    if isnothing(value)
        return default_padding_pixel(T)
    end

    return convert(T, value)
end

function default_padding_pixel(::Type{T}) where {T}
    if T <: Gray
        return T(1)
    end

    if T <: RGB
        return T(1, 1, 1)
    end

    if T <: Colorant
        return convert(T, Gray(1))
    end

    return one(T)
end

function thin_image(
    image;
    threshold::Real=0.5,
    morphology_radius::Integer=0,
    isolated_pixel_radius::Integer=0,
)
    cutoff = clamp(Float64(threshold), 0.0, 1.0)
    foreground = map(image) do pixel
        Float64(Gray(pixel)) < cutoff
    end
    foreground = remove_isolated_foreground(foreground; radius=isolated_pixel_radius)
    h, w = size(foreground)
    cv_img = reshape(UInt8.(foreground) .* 0xFF, 1, h, w)
    if morphology_radius > 0
        cv_img = close_foreground_cv(cv_img, morphology_radius)
    end
    skel = zeros(UInt8, 1, h, w)
    element = cv.getStructuringElement(cv.MORPH_CROSS, cv.Size(Int32(3), Int32(3)))
    done = false
    while !done
        eroded = cv.erode(cv_img, element)
        temp = cv.dilate(eroded, element)
        subtracted = cv.subtract(cv_img, temp)
        skel = cv.bitwise_or(skel, subtracted)
        cv_img = eroded
        if cv.countNonZero(cv_img) == 0
            done = true
        end
    end
    skel_2d = dropdims(skel, dims=1)
    return map(skel_2d) do val
        Gray{Float32}(val > 0 ? 0.0f0 : 1.0f0)
    end
end

function close_foreground_cv(img_uint8, radius::Integer)
    radius >= 0 || throw(ArgumentError("morphology_radius must be non-negative"))
    radius == 0 && return img_uint8
    
    # Create a square kernel based on the radius
    ksize = Int32(2 * radius + 1)
    element = cv.getStructuringElement(cv.MORPH_RECT, cv.Size(ksize, ksize))
    
    dilated = cv.dilate(img_uint8, element)
    closed = cv.erode(dilated, element)
    return closed
end

function remove_isolated_foreground(foreground::AbstractMatrix{Bool}; radius::Integer=0)
    radius >= 0 || throw(ArgumentError("isolated_pixel_radius must be non-negative"))
    radius == 0 && return foreground

    cleaned = copy(foreground)
    row_axis = axes(foreground, 1)
    col_axis = axes(foreground, 2)

    for row in row_axis, col in col_axis
        foreground[row, col] || continue

        row_range = max(first(row_axis), row - radius):min(last(row_axis), row + radius)
        col_range = max(first(col_axis), col - radius):min(last(col_axis), col + radius)
        has_neighbor = false

        for neighbor_row in row_range, neighbor_col in col_range
            neighbor_row == row && neighbor_col == col && continue
            if foreground[neighbor_row, neighbor_col]
                has_neighbor = true
                break
            end
        end

        cleaned[row, col] = has_neighbor
    end

    return cleaned
end

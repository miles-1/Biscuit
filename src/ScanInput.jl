module ScanInput

"""
    ScanInput

Turn a user-chosen scan source — one image/PDF file, or a folder of them — into
an ordered list of raster files OpenCV can read.

PDF pages are rasterized once (via bundled `pdftoppm`) into a temp directory that
lives for the duration of `with_scan_input`. Multi-page TIFFs stay as TIFFs and
are expanded when the pages are loaded.
"""

import OpenCV as cv
using Poppler_jll: pdftoppm

export ScanInputSession
export with_scan_input
export open_scan_input
export close_scan_input!
export load_gray_pages
export load_binary_pages
export load_color_pages
export natural_sort
export SCAN_IMAGE_EXTENSIONS
export SCAN_PDF_EXTENSIONS
export PDF_RASTER_DPI
export is_scan_path

const SCAN_IMAGE_EXTENSIONS = (".png", ".jpg", ".jpeg", ".tif", ".tiff")
const SCAN_PDF_EXTENSIONS = (".pdf",)
# Matches the documented "at least 200 dpi" guidance with headroom for data-matrix reads.
const PDF_RASTER_DPI = 300

"""
Resolved scan source. `files` is the ordered list of raster files (PNG/JPEG/TIFF)
to feed OpenCV; PDFs have already been turned into PNGs under `temp_dirs`.
"""
mutable struct ScanInputSession
    source::String
    files::Vector{String}
    temp_dirs::Vector{String}
    output_dir::String
    output_stem::String
end

function is_scan_path(path::AbstractString)::Bool
    s = strip(String(path))
    isempty(s) && return false
    ap = abspath(s)
    return isfile(ap) || isdir(ap)
end

function _scan_ext(path::AbstractString)::String
    return lowercase(splitext(path)[2])
end

function _is_scan_image(path::AbstractString)::Bool
    return _scan_ext(path) in SCAN_IMAGE_EXTENSIONS
end

function _is_scan_pdf(path::AbstractString)::Bool
    return _scan_ext(path) in SCAN_PDF_EXTENSIONS
end

"""
    natural_sort(names)

Sort `page_2.png` before `page_10.png`. Digit runs compare as integers; everything
else is case-insensitive text.
"""
function natural_sort(names::Vector{String})::Vector{String}
    return sort(names; lt=_natural_lt)
end

function _natural_key(s::AbstractString)
    parts = Any[]
    for m in eachmatch(r"\d+|[A-Za-z]+|[^A-Za-z0-9]+", String(s))
        chunk = m.match
        if occursin(r"^\d+$", chunk)
            push!(parts, parse(Int, chunk))
        else
            push!(parts, lowercase(chunk))
        end
    end
    return parts
end

function _natural_lt(a::AbstractString, b::AbstractString)::Bool
    ka = _natural_key(a)
    kb = _natural_key(b)
    n = min(length(ka), length(kb))
    for i in 1:n
        x, y = ka[i], kb[i]
        if x isa Integer && y isa Integer
            x == y || return x < y
        else
            sx, sy = string(x), string(y)
            sx == sy || return sx < sy
        end
    end
    return length(ka) < length(kb)
end

function _cleanup_temps(dirs)
    for dir in dirs
        try
            isdir(dir) && rm(dir; recursive=true, force=true)
        catch
        end
    end
    return nothing
end

"""
Immediate files in `dir` that are scan images or PDFs, naturally sorted.
Subfolders are ignored so page order is just the names in that folder.
"""
function list_folder_scan_names(dir::AbstractString)::Vector{String}
    names = String[]
    for name in readdir(dir)
        startswith(name, ".") && continue
        path = joinpath(dir, name)
        isfile(path) || continue
        if _is_scan_image(name) || _is_scan_pdf(name)
            push!(names, name)
        end
    end
    return natural_sort(names)
end

function rasterize_pdf_to_dir(
    pdf_path::AbstractString,
    out_dir::AbstractString;
    dpi::Integer=PDF_RASTER_DPI,
)::Vector{String}
    isfile(pdf_path) || throw(ArgumentError("PDF not found: $pdf_path"))
    mkpath(out_dir)
    prefix = joinpath(out_dir, "page")
    # `-forcenum` so a one-page PDF is `page-1.png`, same pattern as longer files.
    pdftoppm() do exe
        try
            run(`$exe -png -r $(Int(dpi)) -forcenum -q $pdf_path $prefix`)
        catch e
            error("Failed to rasterize PDF $(pdf_path) at $(dpi) dpi: $e")
        end
    end
    pngs = filter(name -> endswith(lowercase(name), ".png"), readdir(out_dir))
    isempty(pngs) && error("pdftoppm produced no pages from $pdf_path")
    return [joinpath(out_dir, name) for name in natural_sort(pngs)]
end

function expand_scan_file!(temps::Vector{String}, path::AbstractString)::Vector{String}
    if _is_scan_pdf(path)
        dir = mktempdir(; prefix="biscuit_pdf_")
        push!(temps, dir)
        println("Rasterizing PDF at $(PDF_RASTER_DPI) dpi: ", path)
        flush(stdout)
        return rasterize_pdf_to_dir(path, dir)
    elseif _is_scan_image(path)
        return String[String(path)]
    else
        throw(ArgumentError(
            "Unsupported scan file type $(repr(_scan_ext(path))): $path. " *
            "Use PNG, JPEG, TIFF, or PDF."
        ))
    end
end

function _output_stem_for(path::AbstractString, is_directory::Bool)::String
    stem = is_directory ? basename(path) : first(splitext(basename(path)))
    return isempty(stem) ? "scans" : stem
end

"""
    open_scan_input(path)

Resolve `path` into raster files. Call `close_scan_input!` (or use
`with_scan_input`) so PDF temp directories are removed.
"""
function open_scan_input(path::AbstractString)::ScanInputSession
    raw = strip(String(path))
    isempty(raw) && throw(ArgumentError("Scan path is empty."))
    ap = abspath(raw)
    ispath(ap) || throw(ArgumentError("Scan path not found: $ap"))

    temps = String[]
    files = String[]
    try
        if isdir(ap)
            names = list_folder_scan_names(ap)
            isempty(names) && throw(ArgumentError(
                "No PNG, JPEG, TIFF, or PDF files in $ap. Put the scan images " *
                "directly in that folder (subfolders are not read)."
            ))
            for name in names
                append!(files, expand_scan_file!(temps, joinpath(ap, name)))
            end
            return ScanInputSession(ap, files, temps, dirname(ap), _output_stem_for(ap, true))
        else
            append!(files, expand_scan_file!(temps, ap))
            return ScanInputSession(ap, files, temps, dirname(ap), _output_stem_for(ap, false))
        end
    catch
        _cleanup_temps(temps)
        rethrow()
    end
end

function close_scan_input!(session::ScanInputSession)
    _cleanup_temps(session.temp_dirs)
    empty!(session.temp_dirs)
    return nothing
end

function with_scan_input(f::Function, path::AbstractString)
    session = open_scan_input(path)
    try
        return f(session)
    finally
        close_scan_input!(session)
    end
end

function _page_is_empty(img)::Bool
    img isa AbstractArray || return true
    isempty(img) && return true
    return ndims(img) >= 2 && (size(img, ndims(img) - 1) == 0 || size(img, ndims(img)) == 0)
end

# Detection code expects OpenCV's (channels, width, height) layout.
function _ensure_page(img)
    ndims(img) == 3 && return img
    ndims(img) == 2 && return reshape(img, 1, size(img, 1), size(img, 2))
    error("Unexpected scan image array with $(ndims(img)) dimension(s)")
end

function read_pages_from_file(path::AbstractString; flags)::Vector
    file = String(path)
    ret, pages = try
        cv.imreadmulti(file; flags)
    catch
        (false, Any[])
    end
    if ret && !isempty(pages)
        return [_ensure_page(p) for p in pages]
    end
    img = try
        cv.imread(file; flags)
    catch e
        error("Could not load scan image $(file): $e")
    end
    _page_is_empty(img) && error("Could not load scan image: $file")
    return [_ensure_page(img)]
end

function load_scan_pages(session::ScanInputSession; flags)
    pages = Any[]
    for file in session.files
        append!(pages, read_pages_from_file(file; flags))
    end
    isempty(pages) && error("No pages found in scans at $(session.source)")
    return pages
end

load_gray_pages(session::ScanInputSession) =
    load_scan_pages(session; flags=cv.IMREAD_GRAYSCALE)

load_color_pages(session::ScanInputSession) =
    load_scan_pages(session; flags=cv.IMREAD_COLOR)

# Otsu-binarize grayscale pages to pure black/white (ink=0, paper=255).
function load_binary_pages(session::ScanInputSession)
    return map(load_gray_pages(session)) do image_3d
        _, binary = cv.threshold(image_3d, 0.0, 255.0, cv.THRESH_BINARY | cv.THRESH_OTSU)
        binary
    end
end

end # module

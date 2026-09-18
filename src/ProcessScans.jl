module ProcessScans

import OpenCV as cv
using Base64: base64decode
using ..ArchiveUtils
using ..JsonIO
using ..Dmtx: decode_matrix
using ..NameReader: load_name_reader, guess_assignment_names
using ..NameStore: NameImageCandidate, merge_name_images!
using ..ScanInput
using ..Classes: read_roster_table

export process_scans, process_non_biscuit_scans, export_name_training_data, extract_name_field_crops
export snapshot_name_crops, name_crops_dir

const Points2F64 = Vector{NTuple{2,Float64}}
const pdf_width = 612
const pdf_height = 792

function _page_correction(corrections::AbstractDict, ppage_indx::Integer)
    c = get(corrections, string(ppage_indx), nothing)
    return isa(c, AbstractDict) ? c : nothing
end

function _correction_deletes_page(c)::Bool
    return c !== nothing && get(c, "delete", false) === true
end

function _correction_rotates_page(c)::Bool
    return c !== nothing && get(c, "rotate_180", false) === true
end

function rotate_page_180(image_3d::AbstractArray)
    return image_3d[:, end:-1:1, end:-1:1]
end

function rotate_points_180(points, w::Real, h::Real)
    return [(Float64(w) - Float64(p[1]), Float64(h) - Float64(p[2])) for p in points]
end

function maybe_corrected_page(image_3d, corrections::AbstractDict, ppage_indx::Integer)
    c = _page_correction(corrections, ppage_indx)
    _correction_deletes_page(c) && return nothing
    return _correction_rotates_page(c) ? rotate_page_180(image_3d) : image_3d
end

function perspective_transform_points(points, H)::Points2F64
    if isempty(points)
        return Points2F64()
    end
    matrix = Float32.(stack([Tuple(Float64.(p)) for p in points], dims=2))
    pts_array = reshape(matrix, 2, 1, size(matrix, 2))
    mapped = cv.perspectiveTransform(pts_array, H)
    out = Points2F64()
    sizehint!(out, size(mapped, 3))
    for i in axes(mapped, 3)
        push!(out, (Float64(mapped[1, 1, i]), Float64(mapped[2, 1, i])))
    end
    return out
end

# Printed payload is 3 bytes: (assn_id ÷ 256, assn_id % 256, page), then base64.
# A false-positive libdmtx read can yield a shorter string; treat that as no matrix.
function parse_assn_page_payload(decoded::AbstractString)::NamedTuple
    local b
    try
        b = base64decode(decoded)
    catch
        return NamedTuple()
    end
    length(b) < 3 && return NamedTuple()
    assn_id = Int64(b[1]) * 256 + Int64(b[2])
    page = Int64(b[end])
    (assn_id >= 0 && page >= 1) || return NamedTuple()
    return (; assn_id, page)
end

function try_decode_assn_page_matrix(image)::NamedTuple
    decoded = decode_matrix(image)
    isempty(decoded) && return NamedTuple()
    return parse_assn_page_payload(decoded)
end

function find_data_matrix(image_3d::AbstractArray{UInt8, 3}; kernel_size::NTuple{2,Int64}=(3,3))::NamedTuple
    w, h = size(image_3d, 2), size(image_3d, 3)
    # ~15% of the shorter side (250px was used for 1704×2200 scans).
    box_size = ceil(Int64, 0.15 * min(w, h))
    # In Julia OpenCV wrappers, dimensions are (channels, width, height)
    # The datamatrix is in the bottom-left corner: x in 1:box_size, y in h-box_size+1:h
    # So indices are [:, 1:box_size, h-box_size+1:h]
    corner = image_3d[:, 1:box_size, h-box_size+1:h]
    parsed = try_decode_assn_page_matrix(corner)
    if isempty(parsed)
        println("    Attempting morph open for data matrix...")
        kernel = cv.getStructuringElement(cv.MORPH_RECT, cv.Size(Int32.(kernel_size)...))
        corner_patched_3d = cv.morphologyEx(corner, cv.MORPH_OPEN, kernel)
        parsed = try_decode_assn_page_matrix(corner_patched_3d)
    end
    if isempty(parsed)
        println("    No data matrix found on this page.")
        return NamedTuple()
    end
    return parsed
end

function find_anchor_squares(image_3d::AbstractArray{UInt8, 3})::Vector{NTuple{2, Float64}}
    w, h = size(image_3d, 2), size(image_3d, 3)
    # Scale from ~150–300px² on 1704×2200 scans (~3.75e6 pixels).
    n_pixels = w * h
    aamin = max(1, floor(Int64, 4e-5 * n_pixels))
    aamax = ceil(Int64, 8e-5 * n_pixels)
    _, thresh = cv.threshold(image_3d, 0.0, 255.0, cv.THRESH_BINARY_INV | cv.THRESH_OTSU)
    kernel_size = cv.Size(Int32(2), Int32(2))
    kernel = cv.getStructuringElement(cv.MORPH_RECT, kernel_size)
    thresh_closed = cv.morphologyEx(thresh, cv.MORPH_CLOSE, kernel)
    contours, _ = cv.findContours(thresh_closed, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE)
    tiff_anchors = NTuple{2, Float64}[]
    thresh_closed_2d = dropdims(Array(thresh_closed), dims=1)
    for c in contours
        area = cv.contourArea(c)
        if aamin < area < aamax
            (; x, y, width, height) = cv.boundingRect(c)
            if 0.8 < width / height < 1.25
                # OpenCV arrays here are (channels, width, height), so this 2D
                # matrix is indexed as [x, y] after dropping channel dimension.
                roi = @view thresh_closed_2d[x+1:x+width, y+1:y+height]
                ink_pixels = count(>(0), roi)
                fill_ratio = ink_pixels / (width * height)
                if fill_ratio > 0.75
                    M = cv.moments(c)
                    m00 = M.m00
                    if m00 != 0.0
                        cx = M.m10 / m00
                        cy = M.m01 / m00
                        push!(tiff_anchors, (cx, cy))
                    end
                end
            end
        end
    end
    return tiff_anchors
end

# Real printed anchors sit near the page margin (~33% of page width apart). Clustered
# detections or interior hits are almost always false positives.
function anchors_have_implausible_geometry(
    tiff_anchors::AbstractVector,
    w::Real,
    h::Real;
    min_pair_frac::Float64=0.20,
    max_edge_frac::Float64=0.10,
)::Bool
    w <= 0 && return false
    min_pair = min_pair_frac * w
    min_pair2 = min_pair * min_pair
    max_edge = max_edge_frac * w
    n = length(tiff_anchors)
    for i in 1:n
        (x, y) = tiff_anchors[i]
        if min(x, y, w - x, h - y) > max_edge
            return true
        end
        for j in (i + 1):n
            (x2, y2) = tiff_anchors[j]
            dx = x - x2
            dy = y - y2
            if dx * dx + dy * dy < min_pair2
                return true
            end
        end
    end
    return false
end

function load_page_elements_data(page_elements_file::String)
    return Dict(
        parse(Int64, assn_id) => Dict(
            parse(Int64, page) => elems for (page, elems) in page_dict
        ) for (assn_id, page_dict) in json_parsefile(page_elements_file)
    )
end

function _english_join_ints(indices::Vector{Int64})::String
    n = length(indices)
    n == 0 && return ""
    n == 1 && return string(indices[1])
    n == 2 && return "$(indices[1]) and $(indices[2])"
    return join(view(indices, 1:n-1), ", ") * ", and $(indices[n])"
end

function extract_tiff_data(
    scan::ScanInputSession;
    corrections::Dict{String, Any}=Dict{String, Any}(),
    page_elements_data,
)::Tuple{Dict{Int64, Dict{Int64, NamedTuple}}, Dict{Int64, NTuple{2, Int64}}, Dict{Int64, Dict{String, Any}}}
    tiff_data = Dict{Int64, Dict{Int64, NamedTuple}}()
    ppage_dict = Dict{Int64, NTuple{2, Int64}}()
    identify_issues = Dict{Int64, Dict{String, Any}}()
    decoded = NamedTuple[]
    printstyled("Reading Data Matrices and Locating Anchors\n"; bold=true, underline=true)
    pages = load_binary_pages(scan)
    for (ppage_indx, image_3d) in enumerate(pages)
        println("- Page $ppage_indx...")
        c = _page_correction(corrections, ppage_indx)
        if _correction_deletes_page(c)
            println(" "^4 * "Deleted in Verify Scans — skipping.")
            continue
        end
        if _correction_rotates_page(c)
            image_3d = rotate_page_180(image_3d)
            println(" "^4 * "Rotated 180°")
        end
        w, h = Int64(size(image_3d, 2)), Int64(size(image_3d, 3))

        dm_data = if isnothing(c) || !haskey(c, "assn_id")
            find_data_matrix(image_3d)
        else
            @assert haskey(c, "assn_id") "correction for page $ppage_indx missing assn_id"
            (; assn_id=Int64(c["assn_id"]), page=Int64(c["page"]))
        end

        tiff_anchors = if !isnothing(c) && haskey(c, "tiff_anchors")
            pts = [Tuple(Float64.(a)) for a in c["tiff_anchors"]]
            _correction_rotates_page(c) ? rotate_points_180(pts, w, h) : pts
        else
            find_anchor_squares(image_3d)
        end
        if isempty(dm_data)
            identify_issues[ppage_indx] = Dict{String, Any}(
                "identify_error" => "no_datamatrix",
                "tiff_anchors" => tiff_anchors,
            )
            continue
        end
        (; assn_id, page) = dm_data
        println(" "^4 * "Assn $assn_id, page $page")
        push!(decoded, (; ppage_indx, assn_id, page, tiff_anchors, w, h))
    end

    pair_to_pages = Dict{Tuple{Int64, Int64}, Vector{Int64}}()
    for d in decoded
        push!(get!(() -> Int64[], pair_to_pages, (d.assn_id, d.page)), d.ppage_indx)
    end
    for ((assn_id, page), ppages) in pairs(pair_to_pages)
        length(ppages) > 1 || continue
        sorted = sort(ppages)
        both_or_all = length(sorted) == 2 ? "both" : "all"
        println("Pages $(_english_join_ints(sorted)) $both_or_all decoded as assn $assn_id page $page — leaving $both_or_all unidentified")
    end

    for d in decoded
        assn_pages = get(page_elements_data, d.assn_id, nothing)
        error_kind = if assn_pages === nothing
            "unknown_assn"
        elseif !haskey(assn_pages, d.page)
            "unknown_page"
        elseif length(pair_to_pages[(d.assn_id, d.page)]) > 1
            "duplicate"
        else
            nothing
        end
        if error_kind === nothing
            assn_id_dict = get!(() -> Dict{Int64, NamedTuple}(), tiff_data, d.assn_id)
            ppage_dict[d.ppage_indx] = (d.assn_id, d.page)
            assn_id_dict[d.page] = (; tiff_anchors=d.tiff_anchors, w=d.w, h=d.h)
            continue
        end
        if error_kind != "duplicate"
            println("Page $(d.ppage_indx): decoded assn $(d.assn_id) page $(d.page) is not in this assignment — leaving unidentified")
        end
        issue = Dict{String, Any}(
            "identify_error" => error_kind,
            "decoded_assn_id" => d.assn_id,
            "decoded_page" => d.page,
            "tiff_anchors" => d.tiff_anchors,
        )
        if error_kind == "duplicate"
            issue["duplicate_ppages"] = sort(pair_to_pages[(d.assn_id, d.page)])
        end
        identify_issues[d.ppage_indx] = issue
    end
    return tiff_data, ppage_dict, identify_issues
end

function get_mapped_data(
    ;
    tiff_data::Dict{Int64, Dict{Int64, NamedTuple}},
    page_elements_data,
)
    mapped_data = Dict{Int64, Dict{Int64, NamedTuple}}()
    for (assn_id, page_dict) in pairs(tiff_data)
        mapped_assn_id_data = get!(() -> Dict{Int64, NamedTuple}(), mapped_data, assn_id)
        assn_pages = get(page_elements_data, assn_id, nothing)
        if assn_pages === nothing
            println(" "^4 * "Unknown assignment $assn_id — skipping mapping.")
            continue
        end
        for (p_indx, p_dict) in pairs(page_dict)
            (tiff_anchors, w, h) = p_dict
            elems = get(assn_pages, p_indx, nothing)
            if elems === nothing
                println(" "^4 * "Unknown page $p_indx for assignment $assn_id — skipping mapping.")
                continue
            end
            anchors = [Tuple(Float64.(a)) for a in get(elems, "anchors", [])]
            q_heights = [Tuple(Float64.(b)) for b in get(elems, "q_heights", [])]
            num_tiff_anchors = length(tiff_anchors)
            num_anchors = length(anchors)
            num_questions = length(q_heights)
            # Reject too few detections, more detections than PDF anchors, clustered
            # detections, or hits that are not near a page edge.
            bad_anchor_geometry = anchors_have_implausible_geometry(tiff_anchors, w, h)
            is_major_anchor_mismatch = num_tiff_anchors < 6 || num_tiff_anchors > num_anchors || bad_anchor_geometry
            H = nothing
            if !is_major_anchor_mismatch && !isempty(anchors)
                known_anchors = NTuple{2,Float64}[]
                detected_anchors = NTuple{2,Float64}[]
                scaled_anchors = [(x/pdf_width, y/pdf_width) for (x,y) in anchors]
                for ta in tiff_anchors
                    (tx, ty) = ta ./ w
                    _, indx = findmin(((sx, sy),) -> sum((sx - tx)^2 + (sy - ty)^2), scaled_anchors)
                    popat!(scaled_anchors, indx)
                    push!(detected_anchors, ta)
                    push!(known_anchors, popat!(anchors, indx))
                end
                src_matrix = Float32.(stack(known_anchors, dims=2))
                dst_matrix = Float32.(stack(detected_anchors, dims=2))
                src_pts = reshape(src_matrix, 2, 1, size(src_matrix, 2))
                dst_pts = reshape(dst_matrix, 2, 1, size(dst_matrix, 2))
                H, _ = cv.findHomography(src_pts, dst_pts; method=cv.RANSAC, ransacReprojThreshold=5.0)
            end
            if is_major_anchor_mismatch || isnothing(H) || isempty(H)
                reason = if bad_anchor_geometry
                    "Homography skipped (implausible anchor geometry)"
                elseif num_tiff_anchors < 6 || num_tiff_anchors > num_anchors
                    "Homography skipped (found $num_tiff_anchors anchors; need 6-$num_anchors)"
                else
                    "Homography calculation failed"
                end
                println(" "^4 * "$reason — leaving page $p_indx unscanned (fix anchors via Verify Scans).")
                mapped_assn_id_data[p_indx] = (; num_tiff_anchors, num_questions)
                continue
            end
            mapped_bubble_points = perspective_transform_points(get(elems, "bubbles", []), H)
            mapped_q_height = perspective_transform_points(q_heights, H)
            mapped_q_heights = last.(mapped_q_height)
            mapped_name_box_corners = perspective_transform_points(get(elems, "name_box_corners", []), H)
            mapped_name_field_corners = perspective_transform_points(get(elems, "name_field_corners", []), H)
            mapped_assn_id_data[p_indx] = (;
                num_tiff_anchors,
                num_questions,
                mapped_q_heights,
                mapped_bubble_points,
                mapped_name_box_corners,
                mapped_name_field_corners,
            )
        end
    end
    return mapped_data
end

function black_pixel_proportion_in_radius(frame_array::Matrix{UInt8}, bubble_point::NTuple{2, Int64})::Float64
    w, h = size(frame_array)
    radius = ceil(Int64, 0.004 * min(w, h)) # ~7px on 1704×2200 scans.
    bx, by = bubble_point
    ink = 0
    total = 0
    r2 = radius^2
    for y in max(1, by - radius):min(h, by + radius)
        for x in max(1, bx - radius):min(w, bx + radius)
            if (x - bx)^2 + (y - by)^2 <= r2
                total += 1
                # OpenCV wrappers here expose grayscale pages as [x, y].
                if frame_array[x, y] < 255
                    ink += 1
                end
            end
        end
    end
    return total == 0 ? 0.0 : ink / total
end

function get_question_info_by_assn(
    scan::ScanInputSession;
    mapped_data::Dict{Int64, Dict{Int64, NamedTuple}},
    page_elements_data,
    ppage_dict::Dict{Int64, NTuple{2, Int64}},
    corrections::Dict{String, Any}=Dict{String, Any}(),
)::Dict{Int64, Vector{NamedTuple}}
    pages = load_binary_pages(scan)
    assn_data = Dict{Int64, Vector{NamedTuple}}()
    printstyled("Collecting Mapped Page Elements\n"; bold=true, underline=true)
    for (ppage_indx, image_3d) in enumerate(pages)
        if !haskey(ppage_dict, ppage_indx) continue end
        image_3d = maybe_corrected_page(image_3d, corrections, ppage_indx)
        image_3d === nothing && continue
        println("- Page $ppage_indx")
        (assn_id, page) = ppage_dict[ppage_indx]
        mapped_nt = get(get(mapped_data, assn_id, Dict{Int64, NamedTuple}()), page, nothing)
        if mapped_nt === nothing
            println(" "^4 * "No mapped data for assn $assn_id page $page — skipping.")
            continue
        end
        question_vector = get!(assn_data, assn_id, Vector{NamedTuple}())
        if !haskey(mapped_nt, :mapped_q_heights)
            # Keep one stub per expected question so ordering still matches selection.json;
            # no bubble densities / q_height until Verify Scans corrections re-run processing.
            n_q = Int(get(mapped_nt, :num_questions, 0))
            println(" "^4 * "Page $page unscanned ($n_q question stub(s)).")
            for _ in 1:n_q
                push!(question_vector, (; page))
            end
        else
            mapped_q_heights = get(mapped_nt, :mapped_q_heights, Float64[])
            mapped_bubble_points = get(mapped_nt, :mapped_bubble_points, Points2F64())
            page_elements_nt = get(get(page_elements_data, assn_id, Dict()), page, nothing)
            if page_elements_nt === nothing
                println(" "^4 * "Unknown page $page for assignment $assn_id — skipping.")
                continue
            end
            q_heights = [Tuple(Float64.(b)) for b in get(page_elements_nt, "q_heights", [])]
            bubbles = [Tuple(Float64.(b)) for b in get(page_elements_nt, "bubbles", [])]
            num_qs = length(q_heights)
            bubble_zip = collect(zip(mapped_bubble_points, bubbles))
            frame_array = dropdims(Array(image_3d), dims=1)
            
            for (qindx, (mqh, qs)) in enumerate(zip(mapped_q_heights, q_heights))
                end_height = qindx == num_qs ? Inf : last(q_heights[qindx+1])
                contained_bubbles = filter(z -> last(qs) < last(last(z)) < end_height, bubble_zip)
                q_height = floor(Int, mqh)
                if isempty(contained_bubbles)
                    push!(question_vector, (; page, q_height))
                    continue
                end
                mapped_bubble_centers = map(((mapped_bubbles, _),) -> round.(Int64, mapped_bubbles), contained_bubbles)
                is_true_false = if length(contained_bubbles) >= 2
                    (_, (x1, _)), (_, (x2, _)) = contained_bubbles[1], contained_bubbles[2]
                    x1 != x2
                else
                    false
                end
                bubble_densities = black_pixel_proportion_in_radius.(
                    Ref(frame_array),
                    is_true_false ? permutedims(reshape(mapped_bubble_centers, 2, :)) : mapped_bubble_centers
                )
                left_bubble_positions = mapped_bubble_centers[1:(1+is_true_false):end]
                push!(question_vector, (; page, q_height, bubble_densities, left_bubble_positions))
            end
        end
    end
    for assn_id in keys(mapped_data)
        get!(assn_data, assn_id, NamedTuple[])
    end
    for (assn_id, questions) in collect(pairs(assn_data))
        assn_pages = get(page_elements_data, assn_id, nothing)
        assn_pages === nothing && continue
        assn_data[assn_id] = _questions_with_missing_page_stubs(questions, assn_pages)
    end
    return assn_data
end

function _questions_with_missing_page_stubs(questions::Vector{NamedTuple}, assn_pages)::Vector{NamedTuple}
    by_page = Dict{Int64, Vector{NamedTuple}}()
    for q in questions
        push!(get!(() -> NamedTuple[], by_page, Int64(q.page)), q)
    end
    out = NamedTuple[]
    for page in sort!(collect(keys(assn_pages)))
        n_expected = length(get(get(assn_pages, page, Dict()), "q_heights", []))
        have = get(by_page, page, NamedTuple[])
        if isempty(have)
            n_expected == 0 && continue
            println(" "^4 * "Missing page $page — adding $n_expected question stub(s).")
            for _ in 1:n_expected
                push!(out, (; page))
            end
        else
            append!(out, have)
        end
    end
    return out
end

# Absolute thresholds were 15 and 3 ink pixels in a radius-7 disk (149 pixels) on 1704×2200 scans.
const MIN_DIFF_THRESH = 0.05
const MIN_GAP_SIZE = 0.02

function get_gap_threshold(data::AbstractVector{<:Real}; min_gap_size::Float64=MIN_GAP_SIZE)::Float64
    # gap threshold
    sorted_data = sort(data)
    for i in 1:(length(sorted_data) - 1)
        gap = sorted_data[i+1] - sorted_data[i]
        if gap >= min_gap_size
            return (sorted_data[i] + sorted_data[i+1]) / 2.0
        end
    end
    return -1
end

function process_assn_data(
    assn_data::Dict{Int64, Vector{NamedTuple}};
    mapped_data::Dict{Int64, Dict{Int64, NamedTuple}},
    output_dir::String,
    min_diff_thresh::Float64=MIN_DIFF_THRESH,
)::Dict{Int64, Dict{String, Any}}
    processed_assn_data = Dict{Int64, Dict{String, Any}}()
    for (assn_id, questions) in pairs(assn_data)
        all_bubble_darknesses = reduce(
            vcat,
            (vec(nt.bubble_densities) for nt in questions if haskey(nt, :bubble_densities));
            init=Float64[],
        )
        processed_questions = if isempty(all_bubble_darknesses)
            questions
        else
            gap_threshold = get_gap_threshold(all_bubble_darknesses)
            new_questions = Vector{NamedTuple}(undef, length(questions))
            for (q_indx, q) in enumerate(questions)
                if !haskey(q, :bubble_densities)
                    new_questions[q_indx] = q
                    continue
                end
                answer = if isone(ndims(q.bubble_densities)) # multiple choice question
                    dens = q.bubble_densities
                    if length(dens) == 1
                        dens[1] < gap_threshold ? :unanswered : 0
                    else
                        first_darkest_indx, second_darkest_indx = partialsortperm(dens, 1:2, rev=true)
                        dark_diff = dens[first_darkest_indx] - dens[second_darkest_indx]
                        if dark_diff > min_diff_thresh
                            first_darkest_indx - 1 # 0-indexing for consistency
                        elseif dens[first_darkest_indx] < gap_threshold
                            :unanswered
                        else
                            :unknown
                        end
                    end
                else # true/false question
                    [
                        if abs(true_bubble - false_bubble) > min_diff_thresh
                            true_bubble > false_bubble
                        elseif true_bubble < gap_threshold && false_bubble < gap_threshold
                            :unanswered
                        else
                            :unknown
                        end
                        for (true_bubble, false_bubble) in eachrow(q.bubble_densities)
                    ]
                end
                # Keep left_bubble_positions for annotated-TIFF labels; drop densities once answer is known.
                new_questions[q_indx] = (;
                    page=q.page,
                    q_height=q.q_height,
                    left_bubble_positions=q.left_bubble_positions,
                    answer,
                )
            end
            new_questions
        end
        entry = Dict{String, Any}("questions" => processed_questions)
        page_dict = get(mapped_data, assn_id, nothing)
        if page_dict !== nothing
            for page in sort!(collect(keys(page_dict)))
                nt = page_dict[page]
                corners = get(nt, :mapped_name_box_corners, nothing)
                if corners !== nothing && !isempty(corners)
                    entry["name_box_corners"] = Dict{String, Any}(
                        "page" => page,
                        "positions" => [[round(Int, x), round(Int, y)] for (x, y) in corners],
                    )
                    break
                end
            end
            for page in sort!(collect(keys(page_dict)))
                nt = page_dict[page]
                field = get(nt, :mapped_name_field_corners, nothing)
                if field !== nothing && length(field) >= 4
                    entry["name_field_corners"] = Dict{String, Any}(
                        "page" => page,
                        "positions" => [[round(Int, x), round(Int, y)] for (x, y) in field[1:4]],
                    )
                    break
                end
            end
        end
        processed_assn_data[assn_id] = entry
    end
    open(joinpath(output_dir, "processed_assn_data.json"), "w") do f; json_print(f, processed_assn_data) end
    return processed_assn_data
end

function _processed_questions(assn_entry)::Vector
    @assert isa(assn_entry, AbstractDict) "processed_assn_data entry must be an object"
    qs = get(assn_entry, "questions", nothing)
    qs === nothing && error("processed_assn_data entry is missing a `questions` array")
    return qs
end

function place_text(text_string::String, frame_cv; text_color::NTuple{3,Int64}, w::Int64, h::Int64, align::Symbol=:right, font_scale::Float64=1.0, thickness::Int64=3, pad_right_corner::Bool=false)
    font = cv.FONT_HERSHEY_SIMPLEX
    sz, _ = cv.getTextSize(text_string, font, font_scale, thickness)
    text_w = sz.width
    # text_h = sz.height
    origin = if align == :right
        padding = pad_right_corner ? 20 : 0
        cv.Point{Int32}(w - text_w - padding, h - padding)
    else
        cv.Point{Int32}(w, h)
    end
    white = (255.0, 255.0, 255.0, 0.0)
    t_color = (Float64.(text_color)..., 0.0)
    cv.putText(frame_cv, text_string, origin, font, font_scale, white, thickness+5, cv.LINE_8, false)
    cv.putText(frame_cv, text_string, origin, font, font_scale, t_color, thickness, cv.LINE_8, false)
end

function get_answer_text(a)::String
    if isa(a, Int64)
        "->"
    elseif a == :unanswered
        "N/A"
    elseif a == :unknown
        "?"
    elseif a
        "T"
    else
        "F"
    end 
end

function save_annotated_assn(
    marked_frames::Vector{Tuple{Int64, AbstractArray{UInt8, 3}}},
    assn_id::Union{Int64, Nothing};
    output_dir::String,
    scan_results::Vector{Dict{String, Any}},
    name_by_ppage::Bool=false,
)::Nothing
    if isempty(marked_frames) return nothing end
    dir_name = isnothing(assn_id) ? "unidentified" : "assn_$assn_id"
    test_dir = joinpath(output_dir, dir_name)
    mkpath(test_dir)
    for (i, (ppage_indx, frame)) in enumerate(marked_frames)
        file_name = string(lpad(name_by_ppage ? ppage_indx : i, 4, '0'), ".png")
        file_path = joinpath(test_dir, file_name)
        cv.imwrite(file_path, frame)
        for res in scan_results
            if res["ppage_indx"] == ppage_indx
                res["image_path"] = joinpath(dir_name, file_name)
                break
            end
        end
    end
    return nothing
end

function generate_marked_tiffs(
    scan::ScanInputSession;
    tiff_data::Dict{Int64, Dict{Int64, NamedTuple}}, 
    mapped_data::Dict{Int64, Dict{Int64, NamedTuple}},
    ppage_dict::Dict{Int64, NTuple{2, Int64}},
    processed_assn_data::Dict{Int64, Dict{String, Any}},
    output_dir::String,
    identify_issues::Dict{Int64, Dict{String, Any}}=Dict{Int64, Dict{String, Any}}(),
    corrections::Dict{String, Any}=Dict{String, Any}(),
)::Nothing
    scan_results = Dict{String, Any}[]
    pages = load_color_pages(scan)
    printstyled("Annotating Pages\n"; bold=true, underline=true)
    if isdir(output_dir)
        rm(output_dir, recursive=true)
        println("The folder $output_dir already existed, so it was deleted.")
    end
    mkdir(output_dir)
    # Collect every annotated frame first, then write each destination once.
    # Streaming writes used to flush on unidentified pages, mix those frames into
    # the next assignment, and delete the assignment folder on resume — so page 89's
    # `assn_X/0001.png` was later overwritten with page 90's pixels.
    identified_frames = Dict{Int64, Vector{Tuple{Int64, AbstractArray{UInt8, 3}, Int64}}}()
    unidentified_frames = Tuple{Int64, AbstractArray{UInt8, 3}}[]
    seen_assn = Set{Int64}()
    for (ppage_indx, frame_cv) in enumerate(pages)
        frame_cv = maybe_corrected_page(frame_cv, corrections, ppage_indx)
        frame_cv === nothing && continue
        w, h = size(frame_cv, 2), size(frame_cv, 3)
        page_info = Dict{String, Any}(
            "ppage_indx" => ppage_indx,
            "width" => w,
            "height" => h,
            "identified" => false
        )
        
        if haskey(ppage_dict, ppage_indx)
            # OpenCV BGR Colors (B, G, R, 0.0)
            blue = (155.0, 12.0, 30.0, 0.0)
            green = (100.0, 187.0, 19.0, 0.0)
            assn_id, page = ppage_dict[ppage_indx]
            
            page_info["identified"] = true
            page_info["assn_id"] = assn_id
            page_info["page"] = page
            page_info["tiff_anchors"] = [[a[1], a[2]] for a in tiff_data[assn_id][page].tiff_anchors]
            
            if assn_id ∉ seen_assn
                push!(seen_assn, assn_id)
                println("- Assn $assn_id...")
            end
            for a in tiff_data[assn_id][page].tiff_anchors
                cv.drawMarker(frame_cv, cv.Point{Int32}(round(Int32, a[1]), round(Int32, a[2])), blue, markerType=cv.MARKER_SQUARE, markerSize=25, thickness=3)
            end
            place_text("Assn ID $assn_id, Page $page", frame_cv; w, h, text_color=(155, 12, 30), pad_right_corner=true)
            mapped_nt = get(get(mapped_data, assn_id, Dict{Int64, NamedTuple}()), page, (; num_tiff_anchors=0, num_questions=0))
            page_info["anchors_ok"] = hasproperty(mapped_nt, :mapped_q_heights)
            if page_info["anchors_ok"]
                for qh in mapped_nt.mapped_q_heights
                    cv.drawMarker(frame_cv, cv.Point{Int32}(round(Int32, w*0.95), round(Int32, qh)), blue, markerType=cv.MARKER_CROSS, markerSize=25, thickness=5)
                end
                for bp in mapped_nt.mapped_bubble_points
                    cv.drawMarker(frame_cv, cv.Point{Int32}(round(Int32, bp[1]), round(Int32, bp[2])), blue, markerType=cv.MARKER_DIAMOND, markerSize=35, thickness=3)
                end
            else
                # Top banner so it does not collide with the Assn ID label at the bottom-right.
                warn = "UNSCANNED - fix anchors in Verify Scans"
                font = cv.FONT_HERSHEY_SIMPLEX
                origin = cv.Point{Int32}(40, 80)
                white = (255.0, 255.0, 255.0, 0.0)
                cv.putText(frame_cv, warn, origin, font, 1.2, white, 8, cv.LINE_8, false)
                cv.putText(frame_cv, warn, origin, font, 1.2, green, 3, cv.LINE_8, false)
            end
            processed_assn_nt_vec = filter(
                i -> i.page == page && haskey(i, :left_bubble_positions),
                _processed_questions(get(processed_assn_data, assn_id, Dict("questions" => NamedTuple[]))),
            )
            for (;answer, left_bubble_positions) in processed_assn_nt_vec
                args(x,y) = (text_color=(155, 12, 30), w=round(Int64, x)-35, h=round(Int64, y)+10)
                if isa(answer, Vector)
                    for (a, (x,y)) in zip(answer, left_bubble_positions)
                        answer_text = get_answer_text(a)
                        place_text(answer_text, frame_cv; args(x,y)...)
                    end
                else
                    answer_text = get_answer_text(answer)
                    (x,y) = left_bubble_positions[isa(answer, Symbol) ? 1 : answer+1] # shift index for 0-indexing
                    place_text(answer_text, frame_cv; args(x,y)...)
                end
            end
            push!(scan_results, page_info)
            push!(get!(Vector{Tuple{Int64, AbstractArray{UInt8, 3}, Int64}}, identified_frames, assn_id),
                (ppage_indx, frame_cv, page))
        else
            issue = get(identify_issues, ppage_indx, Dict{String, Any}("identify_error" => "no_datamatrix"))
            merge!(page_info, issue)
            blue = (155.0, 12.0, 30.0, 0.0)
            for a in get(issue, "tiff_anchors", [])
                (ax, ay) = Tuple(Float64.(a))
                cv.drawMarker(frame_cv, cv.Point{Int32}(round(Int32, ax), round(Int32, ay)), blue, markerType=cv.MARKER_SQUARE, markerSize=25, thickness=3)
            end
            push!(scan_results, page_info)
            push!(unidentified_frames, (ppage_indx, frame_cv))
        end
    end
    for assn_id in sort!(collect(keys(identified_frames)))
        frames = identified_frames[assn_id]
        sort!(frames; by = t -> (t[3], t[1]))
        batch = Tuple{Int64, AbstractArray{UInt8, 3}}[]
        for (ppage_indx, frame, _) in frames
            push!(batch, (ppage_indx, frame))
        end
        save_annotated_assn(batch, assn_id; output_dir, scan_results)
    end
    save_annotated_assn(unidentified_frames, nothing; output_dir, scan_results, name_by_ppage=true)
    
    # Save scan_results.json
    open(joinpath(output_dir, "scan_results.json"), "w") do f
        json_print(f, scan_results)
    end
    write_assn_page_counts(output_dir)
    return nothing
end

function write_assn_page_counts(annotated_dir::String)::Nothing
    annotated_dir = abspath(annotated_dir)
    counts = Dict{String, Int}()
    isdir(annotated_dir) || return nothing
    for name in readdir(annotated_dir)
        startswith(name, "assn_") || continue
        dir = joinpath(annotated_dir, name)
        isdir(dir) || continue
        n = count(fname -> endswith(lowercase(fname), ".png"), readdir(dir))
        counts[String(name[6:end])] = n
    end
    open(joinpath(dirname(annotated_dir), "assn_page_counts.json"), "w") do f
        json_print(f, counts)
    end
    return nothing
end

const NAME_BOX_WARP_WIDTH = 539 # original box is 200ptx40pt with 2pt inset, so scale by 2.75
const NAME_BOX_WARP_HEIGHT = 99
# Typst name field is 200pt x 55pt at 2.75x (line 13pt above the bottom).
const NAME_FIELD_WARP_WIDTH = 550
const NAME_FIELD_WARP_HEIGHT = 151

function _corner_xy(point)::NTuple{2, Float64}
    if point isa AbstractVector && length(point) >= 2
        return (Float64(point[1]), Float64(point[2]))
    elseif point isa Tuple && length(point) >= 2
        return (Float64(point[1]), Float64(point[2]))
    end
    throw(ArgumentError("Expected a 2D point, got $(repr(point))"))
end

"""
Perspective-warp a 4-corner name box (TL, TR, BL, BR) from `image` into a fixed
`width`×`height` rectangle (default 200×40, matching Typst name-box size in pt).
"""
function warp_name_box_crop(
    image,
    corners4;
    width::Int=NAME_BOX_WARP_WIDTH,
    height::Int=NAME_BOX_WARP_HEIGHT,
)
    length(corners4) == 4 || throw(ArgumentError("Expected 4 corners, got $(length(corners4))"))
    src = Float32.(stack([_corner_xy(p) for p in corners4], dims=2))
    src_pts = reshape(src, 2, 1, 4)
    dst = Float32[0 width 0 width; 0 0 height height]
    dst_pts = reshape(dst, 2, 1, 4)
    M = cv.getPerspectiveTransform(src_pts, dst_pts)
    return cv.warpPerspective(image, M, cv.Size{Int32}(Int32(width), Int32(height)))
end

const NAME_CROPS_DIRNAME = "name_crops"
const NAME_TABLE_CROPS_SUBDIR = "table"
const NAME_FIELD_CROPS_SUBDIR = "field"

name_crops_dir(archive_dir::AbstractString)::String = joinpath(String(archive_dir), NAME_CROPS_DIRNAME)

function _name_corner_group(entry, key::AbstractString)
    isa(entry, AbstractDict) || return nothing
    group = get(entry, key, nothing)
    isa(group, AbstractDict) || return nothing
    haskey(group, "page") && haskey(group, "positions") || return nothing
    positions = group["positions"]
    isa(positions, AbstractVector) || return nothing
    (isempty(positions) || length(positions) % 4 != 0) && return nothing
    return (page=Int64(group["page"]), positions=positions)
end

"""
    snapshot_name_crops(; scan, processed_assn_data, ppage_dict, archive_dir)

Cut the handwritten name-table boxes and the printed name line out of the raw
scans and store them, unlabeled, in the archive under `name_crops/`.

This happens during processing rather than at export for two reasons. The
annotated scans grading works from have marks drawn on them, which is not what
the name reader sees when it reads a name. And the pages used for detection have
been Otsu-binarized, which throws away the grayscale that lets training vary its
black-and-white threshold.

Which student each crop belongs to is only settled once grading finishes, so the
file names here are assignment ids. Returns the folder, or `nothing` when the
assignment has no name marks at all.
"""
function snapshot_name_crops(;
    scan::ScanInputSession,
    processed_assn_data::Dict{Int64, Dict{String, Any}},
    ppage_dict::Dict{Int64, NTuple{2, Int64}},
    archive_dir::String,
    corrections::Dict{String, Any}=Dict{String, Any}(),
)::Union{String, Nothing}
    wanted = NamedTuple[]
    for assn_id in sort!(collect(keys(processed_assn_data)))
        entry = processed_assn_data[assn_id]
        table = _name_corner_group(entry, "name_box_corners")
        field = _name_corner_group(entry, "name_field_corners")
        (table === nothing && field === nothing) && continue
        push!(wanted, (; assn_id, table, field))
    end
    isempty(wanted) && return nothing

    output_dir = name_crops_dir(archive_dir)
    rm(output_dir; recursive=true, force=true)
    mkpath(joinpath(output_dir, NAME_TABLE_CROPS_SUBDIR))
    mkpath(joinpath(output_dir, NAME_FIELD_CROPS_SUBDIR))

    ppage_of = Dict((assn_id, page) => ppage for (ppage, (assn_id, page)) in pairs(ppage_dict))
    printstyled("Saving Name Crops\n"; bold=true, underline=true)
    pages = load_gray_pages(scan)
    n_table = 0
    n_field = 0

    for item in wanted
        for (group, subdir) in ((item.table, NAME_TABLE_CROPS_SUBDIR), (item.field, NAME_FIELD_CROPS_SUBDIR))
            group === nothing && continue
            ppage = get(ppage_of, (item.assn_id, group.page), nothing)
            (ppage === nothing || ppage < 1 || ppage > length(pages)) && continue
            page_image = maybe_corrected_page(pages[ppage], corrections, ppage)
            page_image === nothing && continue
            is_table = subdir == NAME_TABLE_CROPS_SUBDIR
            width = is_table ? NAME_BOX_WARP_WIDTH : NAME_FIELD_WARP_WIDTH
            height = is_table ? NAME_BOX_WARP_HEIGHT : NAME_FIELD_WARP_HEIGHT
            n_boxes = length(group.positions) ÷ 4
            for box in 1:n_boxes
                warped = warp_name_box_crop(page_image, group.positions[(4box - 3):(4box)]; width, height)
                out_path = if is_table
                    box_dir = joinpath(output_dir, subdir, string(item.assn_id))
                    mkpath(box_dir)
                    joinpath(box_dir, string(lpad(box, 2, '0'), ".png"))
                else
                    joinpath(output_dir, subdir, string(item.assn_id, ".png"))
                end
                cv.imwrite(out_path, warped)
                is_table ? (n_table += 1) : (n_field += 1)
            end
        end
    end

    println("Saved $n_table name-table crop(s) and $n_field name-line crop(s) to the archive.")
    return output_dir
end

# Crops of a student's name from a single assignment, as candidates for the class store.
function _name_crop_candidates_for_assn(
    crops_dir::AbstractString,
    assn_id::Integer,
    student::AbstractString,
)::Vector{NameImageCandidate}
    candidates = NameImageCandidate[]
    table_dir = joinpath(crops_dir, NAME_TABLE_CROPS_SUBDIR, string(assn_id))
    if isdir(table_dir)
        for file in sort(readdir(table_dir))
            endswith(lowercase(file), ".png") || continue
            push!(candidates, NameImageCandidate(String(student), :table, joinpath(table_dir, file)))
        end
    end
    field_path = joinpath(crops_dir, NAME_FIELD_CROPS_SUBDIR, string(assn_id, ".png"))
    isfile(field_path) && push!(candidates, NameImageCandidate(String(student), :assn, field_path))
    return candidates
end

# Archives processed before name crops were snapshotted have no `name_crops/`, so fall back
# to cutting the name table out of the annotated scans, which is what used to happen.
function _legacy_name_table_candidates(
    processed::AbstractDict,
    grading::AbstractDict,
    annotated_scan_folder::AbstractString,
    scratch_dir::AbstractString,
)::Vector{NameImageCandidate}
    scan_results_path = joinpath(annotated_scan_folder, "scan_results.json")
    scan_results = isfile(scan_results_path) ? json_parsefile(scan_results_path) : Any[]
    page_image = Dict{Tuple{Int64, Int64}, String}()
    for res in scan_results
        isa(res, AbstractDict) || continue
        get(res, "identified", false) || continue
        haskey(res, "assn_id") && haskey(res, "page") && haskey(res, "image_path") || continue
        page_image[(Int64(res["assn_id"]), Int64(res["page"]))] = String(res["image_path"])
    end

    candidates = NameImageCandidate[]
    page_cache = Dict{String, Any}()
    for assn_id in _processed_assn_ids(processed)
        table = _name_corner_group(_processed_assn_entry(processed, assn_id), "name_box_corners")
        table === nothing && continue
        student = _graded_student_name(grading, assn_id)
        student === nothing && continue

        img_rel = get(page_image, (assn_id, table.page)) do
            joinpath("assn_$assn_id", string(lpad(table.page, 4, '0'), ".png"))
        end
        img_path = joinpath(annotated_scan_folder, img_rel)
        isfile(img_path) || continue
        image = get!(() -> cv.imread(img_path), page_cache, img_path)

        assn_dir = joinpath(scratch_dir, string(assn_id))
        mkpath(assn_dir)
        for box in 1:(length(table.positions) ÷ 4)
            warped = warp_name_box_crop(image, table.positions[(4box - 3):(4box)])
            out_path = joinpath(assn_dir, string(lpad(box, 2, '0'), ".png"))
            cv.imwrite(out_path, warped)
            push!(candidates, NameImageCandidate(student, :table, out_path))
        end
    end
    return candidates
end

function _graded_student_name(grading::AbstractDict, assn_id::Integer)::Union{Nothing, String}
    entry = get(grading, string(assn_id), nothing)
    isa(entry, AbstractDict) || return nothing
    name = get(entry, "name", nothing)
    (isa(name, AbstractString) && !isempty(strip(name))) || return nothing
    return String(strip(name))
end

"""
    export_name_training_data(; processed_assn_data_file, grading_data_file, archive_dir, class_name, ...)

Label the archive's name crops with the student names grading settled on and merge
them into `class_name`'s app-managed store. Crops whose pixels are already stored
for that student are skipped, so re-exporting, or processing a later batch of the
same assignment, adds only what is new.

Returns `(; images_dir, added, skipped, students)`, or `nothing` when the
assignment carries no name marks.
"""
function export_name_training_data(;
    processed_assn_data_file::String,
    grading_data_file::String,
    archive_dir::String,
    class_name::AbstractString,
    annotated_scan_folder::Union{Nothing, AbstractString}=nothing,
)
    @assert isfile(processed_assn_data_file) "Missing processed_assn_data.json: $processed_assn_data_file"
    @assert isfile(grading_data_file) "Missing grading_data.json: $grading_data_file"
    isempty(strip(String(class_name))) && throw(ArgumentError("`class_name` is required to store name training data."))

    processed = json_parsefile(processed_assn_data_file)
    grading = json_parsefile(grading_data_file)
    crops_dir = name_crops_dir(archive_dir)

    if isdir(crops_dir)
        candidates = NameImageCandidate[]
        for assn_id in _processed_assn_ids(processed)
            student = _graded_student_name(grading, assn_id)
            student === nothing && continue
            append!(candidates, _name_crop_candidates_for_assn(crops_dir, assn_id, student))
        end
        return _merge_and_report(class_name, candidates)
    end

    has_name_table = any(
        assn_id -> _name_corner_group(_processed_assn_entry(processed, assn_id), "name_box_corners") !== nothing,
        _processed_assn_ids(processed),
    )
    has_name_table || return nothing
    annotated_scan_folder === nothing && return nothing
    isdir(annotated_scan_folder) || return nothing
    println("This archive predates saved name crops; cutting the name table from the annotated scans instead.")
    return mktempdir() do scratch
        _merge_and_report(
            class_name,
            _legacy_name_table_candidates(processed, grading, annotated_scan_folder, scratch),
        )
    end
end

function _merge_and_report(class_name::AbstractString, candidates::Vector{NameImageCandidate})
    isempty(candidates) && return nothing
    result = merge_name_images!(class_name, candidates)
    println(
        "Name training data for $(class_name): added $(result.added) image(s) across ",
        "$(result.students) student(s), skipped $(result.skipped) already stored.",
    )
    println("Stored in: $(result.images_dir)")
    return result
end

function process_scans(
    scan_path::String;
    assn_versions_file::String,
    corrections::Dict{String, Any}=Dict{String, Any}(),
    namereader_file::Union{Nothing, AbstractString}=nothing,
    output_name::Union{Nothing, AbstractString}=nothing,
)
    assn_archive_dir = dirname(abspath(assn_versions_file))
    stem = if output_name !== nothing && !isempty(strip(String(output_name)))
        strip(String(output_name))
    else
        first(splitext(basename(assn_versions_file)))
    end
    assn_archive_file = joinpath(assn_archive_dir, stem * ".assn")
    cp(assn_versions_file, assn_archive_file; force=true)
    println("Created: $assn_archive_file (copied from $assn_versions_file)")
    with_scan_input(scan_path) do scan
        println("Reading scans: ", scan.source)
        with_archive_dir(assn_archive_file) do archive_dir
            page_elements_file = joinpath(archive_dir, "page_elements.json")
            @assert isfile(page_elements_file) "Missing page_elements.json in assnversions archive: $assn_versions_file"
            annotated_dir = joinpath(archive_dir, "annotated")
            page_elements_data = load_page_elements_data(page_elements_file)
            tiff_data, ppage_dict, identify_issues = extract_tiff_data(scan; corrections, page_elements_data)
            mapped_data = get_mapped_data(; tiff_data, page_elements_data)
            assn_data = get_question_info_by_assn(scan; mapped_data, page_elements_data, ppage_dict, corrections)
            processed_assn_data = process_assn_data(assn_data; mapped_data, output_dir=archive_dir)
            # Snapshot before annotation: the marks drawn below would otherwise land in the crops.
            snapshot_name_crops(; scan, processed_assn_data, ppage_dict, archive_dir, corrections)
            if namereader_file !== nothing && !isempty(strip(String(namereader_file)))
                apply_name_reader_guesses!(
                    processed_assn_data;
                    scan,
                    ppage_dict,
                    mapped_data,
                    archive_dir,
                    namereader_file=String(namereader_file),
                    corrections,
                )
            end
            generate_marked_tiffs(scan; ppage_dict, tiff_data, mapped_data, processed_assn_data, output_dir=annotated_dir, identify_issues, corrections)
            make_archive_from_dir(archive_dir, assn_archive_file)
            println("Updated: $assn_archive_file (added processed_assn_data.json and annotated scans)")
            stale_tmp = abspath(assn_archive_file) * ".tmp"
            if isdir(stale_tmp)
                rm(stale_tmp; recursive=true, force=true)
                println("Removed stale extract: $stale_tmp")
            end
        end
    end
end

### Non-Biscuit scans ###

# The dummy assignment is one unanswered essay at the top of page 1, so grading has a single
# whole-submission score to fill in. `points` stays integral when the caller gave a whole number.
function _non_biscuit_master(;
    assn_type::AbstractString,
    title::AbstractString,
    total_points::Real,
    num_students::Int,
)::Dict{String, Any}
    points = isinteger(total_points) ? Int64(total_points) : Float64(total_points)
    return Dict{String, Any}(
        "assn_type" => String(assn_type),
        "title" => String(title),
        "version_count" => num_students,
        "questions" => Any[Dict{String, Any}(
            "type" => "essay",
            "body" => "",
            "points" => points,
        )],
    )
end

function _non_biscuit_selection(num_students::Int)::Dict{String, Any}
    versions = Any[Dict{String, Any}("is_key" => true, "questions" => Any[0])]
    for assn_id in 0:(num_students - 1)
        push!(versions, Dict{String, Any}("assn_id" => assn_id, "questions" => Any[0]))
    end
    return Dict{String, Any}("versions" => versions)
end

# Grading pads its question list from `q_heights`, so page 1 declares the one question and the
# remaining pages declare none. Anchors and bubbles stay empty: nothing is detected on these scans.
function _non_biscuit_page_elements(num_students::Int, pages_per_student::Int)::Dict{String, Any}
    page_elements = Dict{String, Any}()
    for assn_id in 0:(num_students - 1)
        pages = Dict{String, Any}()
        for page in 1:pages_per_student
            pages[string(page)] = Dict{String, Any}(
                "q_heights" => page == 1 ? Any[Any[0.0, 0.0]] : Any[],
                "bubbles" => Any[],
                "anchors" => Any[],
            )
        end
        page_elements[string(assn_id)] = pages
    end
    return page_elements
end

function _non_biscuit_processed_assn_data(num_students::Int)::Dict{String, Any}
    processed = Dict{String, Any}()
    for assn_id in 0:(num_students - 1)
        processed[string(assn_id)] = Dict{String, Any}(
            "questions" => Any[Dict{String, Any}("page" => 1, "q_height" => 0)],
        )
    end
    return processed
end

function _write_non_biscuit_annotated(pages, output_dir::String; pages_per_student::Int)::Nothing
    if isdir(output_dir)
        rm(output_dir; recursive=true)
    end
    mkpath(output_dir)
    scan_results = Dict{String, Any}[]
    printstyled("Annotating Pages\n"; bold=true, underline=true)
    for (ppage_indx, frame_cv) in enumerate(pages)
        w, h = Int64(size(frame_cv, 2)), Int64(size(frame_cv, 3))
        assn_id = (ppage_indx - 1) ÷ pages_per_student
        page = (ppage_indx - 1) % pages_per_student + 1
        page == 1 && println("- Assn $assn_id...")
        place_text("Assn ID $assn_id, Page $page", frame_cv; w, h, text_color=(155, 12, 30), pad_right_corner=true)
        dir_name = "assn_$assn_id"
        mkpath(joinpath(output_dir, dir_name))
        file_name = string(lpad(page, 4, '0'), ".png")
        cv.imwrite(joinpath(output_dir, dir_name, file_name), frame_cv)
        push!(scan_results, Dict{String, Any}(
            "ppage_indx" => ppage_indx,
            "width" => w,
            "height" => h,
            "identified" => true,
            "assn_id" => assn_id,
            "page" => page,
            "anchors_ok" => true,
            "tiff_anchors" => Any[],
            "image_path" => joinpath(dir_name, file_name),
        ))
    end
    open(joinpath(output_dir, "scan_results.json"), "w") do f
        json_print(f, scan_results)
    end
    return nothing
end

"""
    process_non_biscuit_scans(scan_path; pages_per_student, total_points, assn_type, kwargs...)

Build a gradeable `.assn` archive from scans Biscuit did not generate.

These pages carry no data matrix and no anchors, so page identity comes from position alone:
scan page `i` (1-based) belongs to assignment `(i - 1) ÷ pages_per_student` at its page
`(i - 1) % pages_per_student + 1`. The page count must divide evenly.

The archive describes a one-question dummy assignment worth `total_points`, so the grading
UI has a single score per submission to fill in. Returns the `.assn` path.
"""
function process_non_biscuit_scans(
    scan_path::String;
    pages_per_student::Integer,
    total_points::Real,
    assn_type::AbstractString,
    output_name::Union{Nothing, AbstractString}=nothing,
    class_csv_file::Union{Nothing, AbstractString}=nothing,
)::String
    pages_per_student >= 1 ||
        throw(ArgumentError("`Num Pages Per Student` must be at least 1, got $pages_per_student"))
    (isfinite(total_points) && total_points >= 0) ||
        throw(ArgumentError("`Total Points` must be a nonnegative number, got $total_points"))
    assn_type in ("quiz", "worksheet", "exam") ||
        throw(ArgumentError("`assn_type` must be \"quiz\", \"worksheet\", or \"exam\", got $(repr(assn_type))"))
    if class_csv_file !== nothing && !isfile(class_csv_file)
        throw(ArgumentError("Class roster CSV not found: $class_csv_file"))
    end

    per_student = Int(pages_per_student)
    return with_scan_input(scan_path) do scan
        pages = load_color_pages(scan)
        num_pages = length(pages)
        num_pages > 0 || error("No pages found in scans at $(scan.source)")
        num_pages % per_student == 0 || error(
            "Scans have $num_pages page(s), which is not a multiple of the $per_student " *
            "page(s) per student. Fix the scan or the page count, then try again."
        )
        num_students = num_pages ÷ per_student

        stem = if output_name !== nothing && !isempty(strip(String(output_name)))
            String(strip(String(output_name)))
        else
            scan.output_stem
        end
        assn_archive_file = joinpath(scan.output_dir, stem * ".assn")

        printstyled("Processing Non-Biscuit Scans\n"; bold=true, underline=true)
        println("- Reading scans: ", scan.source)
        println("- $num_pages page(s) at $pages_per_student per student → $num_students submission(s)")
        println("- Dummy $assn_type question worth $total_points point(s)")

        _process_non_biscuit_pages(
            pages, assn_archive_file;
            per_student, num_students, stem, assn_type, total_points, class_csv_file,
        )
    end
end

function _process_non_biscuit_pages(
    pages,
    assn_archive_file::String;
    per_student::Int,
    num_students::Int,
    stem::String,
    assn_type::AbstractString,
    total_points::Real,
    class_csv_file,
)::String
    mktempdir() do build_dir
        write_json(name, data) = open(joinpath(build_dir, name), "w") do f
            json_print(f, data)
        end
        write_json("master.json", _non_biscuit_master(;
            assn_type,
            title=stem,
            total_points,
            num_students,
        ))
        println("Added: master.json")
        write_json("selection.json", _non_biscuit_selection(num_students))
        println("Created: selection.json - $num_students student version(s) and 1 key")
        write_json("page_elements.json", _non_biscuit_page_elements(num_students, per_student))
        println("Created: page_elements.json")
        write_json("var_answers.json", Dict{String, Any}())
        println("Created: var_answers.json")
        write_json("processed_assn_data.json", _non_biscuit_processed_assn_data(num_students))
        println("Created: processed_assn_data.json")

        annotated_dir = joinpath(build_dir, "annotated")
        _write_non_biscuit_annotated(pages, annotated_dir; pages_per_student=per_student)
        write_assn_page_counts(annotated_dir)

        if class_csv_file !== nothing
            cp(class_csv_file, joinpath(build_dir, basename(class_csv_file)); force=true)
            println("Added: $(basename(class_csv_file))")
        end

        make_archive_from_dir(build_dir, assn_archive_file; rebuild=false)
    end
    println("Created: $assn_archive_file")
    stale_tmp = abspath(assn_archive_file) * ".tmp"
    if isdir(stale_tmp)
        rm(stale_tmp; recursive=true, force=true)
        println("Removed stale extract: $stale_tmp")
    end
    return assn_archive_file
end

function _processed_assn_entry(processed_assn_data, assn_id)
    get(processed_assn_data, assn_id) do
        get(processed_assn_data, string(assn_id), nothing)
    end
end

function _processed_assn_ids(processed_assn_data)::Vector{Int64}
    ids = Int64[]
    for k in keys(processed_assn_data)
        if k isa Integer
            push!(ids, Int64(k))
        elseif k isa AbstractString
            parsed = tryparse(Int64, k)
            parsed === nothing || push!(ids, parsed)
        end
    end
    return sort!(unique!(ids))
end

function _ppage_index_from_assn_order(processed_assn_data, assn_page_order)::Dict{Tuple{Int64,Int64},Int}
    page_of = Dict{Tuple{Int64,Int64},Int}()
    for (tiff_page, assn_id) in enumerate(assn_page_order)
        entry = _processed_assn_entry(processed_assn_data, Int64(assn_id))
        isa(entry, AbstractDict) || continue
        field = get(entry, "name_field_corners", nothing)
        isa(field, AbstractDict) || continue
        page_of[(Int64(assn_id), Int64(field["page"]))] = tiff_page
    end
    return page_of
end

function _ppage_index_from_datamatrix(pages)::Dict{Tuple{Int64,Int64},Int}
    page_of = Dict{Tuple{Int64,Int64},Int}()
    for (tiff_page, image) in enumerate(pages)
        dm = find_data_matrix(image)
        isempty(dm) && continue
        page_of[(Int64(dm.assn_id), Int64(dm.page))] = tiff_page
    end
    return page_of
end

"""
    extract_name_field_crops(scan_path, processed_assn_data; kwargs...)
    extract_name_field_crops(pages, processed_assn_data; kwargs...)

Warp each assignment's printed name field to the 550×151 canvas used by NameReader.

Scan page → assignment mapping (first match wins):
- `ppage_of[(assn_id, page)] = tiff_page` if provided
- else decode datamatrices when `decode_datamatrix=true`
- else `assn_page_order[i]` is the assignment id on 1-based scan page `i`

Each result is `(; assn_id, page, tiff_page, crop)` with `crop` a `(height, width)`
`Float32` grayscale image in `[0, 1]`.
"""
function extract_name_field_crops(
    scan_path::String,
    processed_assn_data;
    ppage_of::Union{Nothing,AbstractDict}=nothing,
    assn_page_order::Union{Nothing,AbstractVector{<:Integer}}=nothing,
    decode_datamatrix::Bool=false,
)
    return with_scan_input(scan_path) do scan
        extract_name_field_crops(
            load_binary_pages(scan),
            processed_assn_data;
            ppage_of,
            assn_page_order,
            decode_datamatrix,
        )
    end
end

function extract_name_field_crops(
    scan::ScanInputSession,
    processed_assn_data;
    ppage_of::Union{Nothing,AbstractDict}=nothing,
    assn_page_order::Union{Nothing,AbstractVector{<:Integer}}=nothing,
    decode_datamatrix::Bool=false,
)
    return extract_name_field_crops(
        load_binary_pages(scan),
        processed_assn_data;
        ppage_of,
        assn_page_order,
        decode_datamatrix,
    )
end

function extract_name_field_crops(
    pages,
    processed_assn_data;
    ppage_of::Union{Nothing,AbstractDict}=nothing,
    assn_page_order::Union{Nothing,AbstractVector{<:Integer}}=nothing,
    decode_datamatrix::Bool=false,
)
    page_of = if ppage_of !== nothing
        ppage_of
    elseif decode_datamatrix
        _ppage_index_from_datamatrix(pages)
    elseif assn_page_order !== nothing
        n = min(length(pages), length(assn_page_order))
        if length(pages) != length(assn_page_order)
            println("Name-field extract: TIFF has $(length(pages)) page(s) but assn_page_order has $(length(assn_page_order)) id(s); using the prefix of length $n.")
        end
        _ppage_index_from_assn_order(processed_assn_data, assn_page_order[1:n])
    else
        throw(ArgumentError("extract_name_field_crops needs ppage_of, assn_page_order, or decode_datamatrix=true"))
    end

    results = NamedTuple{(:assn_id, :page, :tiff_page, :crop), Tuple{Int64,Int64,Int,Matrix{Float32}}}[]
    for assn_id in _processed_assn_ids(processed_assn_data)
        entry = _processed_assn_entry(processed_assn_data, assn_id)
        isa(entry, AbstractDict) || continue
        field = get(entry, "name_field_corners", nothing)
        isa(field, AbstractDict) || continue
        page = Int64(field["page"])
        positions = field["positions"]
        isa(positions, AbstractVector) && length(positions) >= 4 || continue
        tiff_page = get(page_of, (assn_id, page), nothing)
        tiff_page === nothing && continue
        (1 <= tiff_page <= length(pages)) || continue
        warped = warp_name_box_crop(
            pages[tiff_page],
            positions[1:4];
            width=NAME_FIELD_WARP_WIDTH,
            height=NAME_FIELD_WARP_HEIGHT,
        )
        push!(results, (; assn_id, page, tiff_page, crop=opencv_gray_to_hw(warped)))
    end
    return results
end

function apply_name_reader_guesses!(
    processed_assn_data::Dict;
    scan::ScanInputSession,
    ppage_dict::Dict{Int64, NTuple{2, Int64}},
    mapped_data,
    archive_dir::String,
    namereader_file::String,
    corrections::Dict{String, Any}=Dict{String, Any}(),
)
    isfile(namereader_file) || throw(ArgumentError("`.namereader` file not found: $namereader_file"))
    bundle = load_name_reader(namereader_file)
    page_of = Dict{Tuple{Int64,Int64}, Int}()
    for (ppage, (assn_id, page)) in pairs(ppage_dict)
        page_of[(assn_id, page)] = ppage
    end

    pages = load_binary_pages(scan)
    for i in eachindex(pages)
        rotated = maybe_corrected_page(pages[i], corrections, i)
        rotated === nothing && continue
        pages[i] = rotated
    end
    extracted = extract_name_field_crops(pages, processed_assn_data; ppage_of=page_of)
    if isempty(extracted)
        println("NameReader: no name-field crops found (assignments need the Typst name-line marks).")
        return processed_assn_data
    end

    crops = [item.crop for item in extracted]
    roster = _archive_roster_names(archive_dir)
    guesses = guess_assignment_names(bundle, crops; roster=roster, allow_unassigned=true)
    assigned = 0
    for guess in guesses
        assn_id = extracted[guess.index].assn_id
        guess.label === nothing && continue
        entry = _processed_assn_entry(processed_assn_data, assn_id)
        entry === nothing && continue
        entry["name"] = match_label_to_roster(guess.label, roster)
        entry["name_guessed"] = true
        assigned += 1
    end
    processed_path = joinpath(archive_dir, "processed_assn_data.json")
    open(processed_path, "w") do f
        json_print(f, processed_assn_data)
    end
    println("NameReader: guessed $assigned / $(length(crops)) name(s)")
    return processed_assn_data
end

function opencv_gray_to_hw(img)::Matrix{Float32}
    a = Array(img)
    gray = ndims(a) == 3 ? dropdims(a; dims=1) : a
    # warpPerspective Size(width, height) → (width, height); NameReader uses (height, width).
    return Float32.(permutedims(gray, (2, 1))) ./ 255.0f0
end

function _archive_roster_names(archive_dir::String)::Union{Nothing, Vector{String}}
    csvs = filter(name -> endswith(lowercase(name), ".csv") && !startswith(name, "."), readdir(archive_dir))
    length(csvs) == 1 || return nothing
    table = try
        read_roster_table(joinpath(archive_dir, only(csvs)))
    catch
        return nothing
    end
    haskey(table, :Student) || return nothing
    names = String.(table.Student)
    return isempty(names) ? nothing : names
end

function match_label_to_roster(label::AbstractString, roster::Union{Nothing, Vector{String}})
    roster === nothing && return String(label)
    target = _normalize_person_key(label)
    for name in roster
        _normalize_person_key(name) == target && return name
    end
    return String(label)
end

function _normalize_person_key(name::AbstractString)
    compact = lowercase(replace(strip(String(name)), r"[\s]+" => ""))
    return replace(compact, '_' => ',')
end

end # module

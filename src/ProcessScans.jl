module ProcessScans

import OpenCV as cv
using Base64: base64decode
using JSON
using ..ArchiveUtils
using ..Dmtx: decode_matrix
using ..NameReader: load_name_reader, guess_assignment_names
using ..Classes: read_roster_table

export process_scans, export_name_training_data, extract_name_field_crops

const Points2F64 = Vector{NTuple{2,Float64}}
const pdf_width = 612
const pdf_height = 792

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

# Load each TIFF page as grayscale, then Otsu-binarize to pure black/white (ink=0, paper=255).
# Accepts color, grayscale, or already-binary scans.
function load_binary_pages(tiff_path::String)
    ret, pages = cv.imreadmulti(tiff_path; flags=cv.IMREAD_GRAYSCALE)
    if !ret
        error("Could not load TIFF file at $tiff_path")
    end
    return map(pages) do image_3d
        _, binary = cv.threshold(image_3d, 0.0, 255.0, cv.THRESH_BINARY | cv.THRESH_OTSU)
        binary
    end
end

function find_data_matrix(image_3d::AbstractArray{UInt8, 3}; kernel_size::NTuple{2,Int64}=(3,3))::NamedTuple
    w, h = size(image_3d, 2), size(image_3d, 3)
    # ~15% of the shorter side (250px was used for 1704×2200 scans).
    box_size = ceil(Int64, 0.15 * min(w, h))
    # In Julia OpenCV wrappers, dimensions are (channels, width, height)
    # The datamatrix is in the bottom-left corner: x in 1:box_size, y in h-box_size+1:h
    # So indices are [:, 1:box_size, h-box_size+1:h]
    corner = image_3d[:, 1:box_size, h-box_size+1:h]
    decoded = decode_matrix(corner)
    if isempty(decoded)
        println("    Attempting morph open for data matrix...")
        kernel = cv.getStructuringElement(cv.MORPH_RECT, cv.Size(Int32.(kernel_size)...))
        corner_patched_3d = cv.morphologyEx(corner, cv.MORPH_OPEN, kernel)
        decoded = decode_matrix(corner_patched_3d)
    end
    if !isempty(decoded)
        b = base64decode(decoded)
        assn_id, page = Int64(b[1]) * 256 + Int64(b[2]), Int64(b[end])
        return (; assn_id, page)
    end
    println("    No data matrix found on this page.")
    return NamedTuple()
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

function extract_tiff_data(tiff_path::String; corrections::Dict{String, Any}=Dict{String, Any}())::Tuple{Dict{Int64, Dict{Int64, NamedTuple}}, Dict{Int64, NTuple{2, Int64}}}
    tiff_data = Dict{Int64, Dict{Int64, NamedTuple}}()
    ppage_dict = Dict{Int64, NTuple{2, Int64}}()
    printstyled("Reading Data Matrices and Locating Anchors\n"; bold=true, underline=true)
    pages = load_binary_pages(tiff_path)
    for (ppage_indx, image_3d) in enumerate(pages)
        println("- Page $ppage_indx...")
        w, h = size(image_3d, 2), size(image_3d, 3)
        
        c = get(corrections, string(ppage_indx), nothing)
        dm_data = if isnothing(c)
            find_data_matrix(image_3d)
        else
            @assert haskey(c, "assn_id") "correction for page $ppage_indx missing assn_id"
            (; assn_id=Int64(c["assn_id"]), page=Int64(c["page"]))
        end
        
        if !isempty(dm_data)
            (; assn_id, page) = dm_data
            tiff_anchors = !isnothing(c) && haskey(c, "tiff_anchors") ? 
                [Tuple(Float64.(a)) for a in c["tiff_anchors"]] : 
                find_anchor_squares(image_3d)
                
            assn_id_dict = get!(() -> Dict{Int64, NamedTuple}(), tiff_data, assn_id)
            ppage_dict[ppage_indx] = (assn_id, page)
            assn_id_dict[page] = (; tiff_anchors, w, h)
        end
    end
    return tiff_data, ppage_dict
end

function get_mapped_data(
    ;
    tiff_data::Dict{Int64, Dict{Int64, NamedTuple}}, 
    page_elements_file::String
)
    page_elements_data = Dict(
        parse(Int64, assn_id) => Dict(
            parse(Int64, page) => elems for (page, elems) in page_dict
        ) for (assn_id, page_dict) in JSON.parsefile(page_elements_file)
    )
    mapped_data = Dict{Int64, Dict{Int64, NamedTuple}}()
    for (assn_id, page_dict) in pairs(tiff_data)
        mapped_assn_id_data = get!(() -> Dict{Int64, NamedTuple}(), mapped_data, assn_id)
        for (p_indx, p_dict) in pairs(page_dict)
            (tiff_anchors, w, h) = p_dict
            elems = page_elements_data[assn_id][p_indx]
            anchors = [Tuple(Float64.(a)) for a in get(elems, "anchors", [])]
            q_heights = [Tuple(Float64.(b)) for b in get(elems, "q_heights", [])]
            num_tiff_anchors = length(tiff_anchors)
            num_anchors = length(anchors)
            num_questions = length(q_heights)
            # Reject too few detections, or more detections than PDF anchors (false positives).
            is_major_anchor_mismatch = num_tiff_anchors < 6 || num_tiff_anchors > num_anchors
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
                reason = is_major_anchor_mismatch ?
                    "Homography skipped (found $num_tiff_anchors anchors; need 6-$num_anchors)" :
                    "Homography calculation failed"
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
    return mapped_data, page_elements_data
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
    tiff_path::String;
    mapped_data::Dict{Int64, Dict{Int64, NamedTuple}},
    page_elements_data,
    ppage_dict::Dict{Int64, NTuple{2, Int64}},
)::Dict{Int64, Vector{NamedTuple}}
    pages = load_binary_pages(tiff_path)
    assn_data = Dict{Int64, Vector{NamedTuple}}()
    printstyled("Collecting Mapped Page Elements\n"; bold=true, underline=true)
    for (ppage_indx, image_3d) in enumerate(pages)
        if !haskey(ppage_dict, ppage_indx) continue end
        println("- Page $ppage_indx")
        (assn_id, page) = ppage_dict[ppage_indx]
        mapped_nt = mapped_data[assn_id][page]
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
            page_elements_nt = page_elements_data[assn_id][page]
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
    return assn_data
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
        all_bubble_darknesses = reduce(vcat, (vec(nt.bubble_densities) for nt in questions if haskey(nt,:bubble_densities)))
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
    open(joinpath(output_dir, "processed_assn_data.json"), "w") do f; JSON.print(f, processed_assn_data) end
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

function save_annotated_assn(marked_frames::Vector{Tuple{Int64, AbstractArray{UInt8, 3}}}, assn_id::Union{Int64, Nothing}; output_dir::String, scan_results::Vector{Dict{String, Any}})::Nothing
    if isempty(marked_frames) return nothing end
    dir_name = isnothing(assn_id) ? "unidentified" : "assn_$assn_id"
    test_dir = joinpath(output_dir, dir_name)
    if isdir(test_dir)
        rm(test_dir, recursive=true)
    end
    mkdir(test_dir)
    for (i, (ppage_indx, frame)) in enumerate(marked_frames)
        file_name = string(lpad(i, 4, '0'), ".png")
        file_path = joinpath(test_dir, file_name)
        cv.imwrite(file_path, frame)
        # Update the scan result for this page
        for res in scan_results
            if res["ppage_indx"] == ppage_indx
                res["image_path"] = joinpath(dir_name, file_name)
                break
            end
        end
    end
    empty!(marked_frames)
    return nothing
end

function generate_marked_tiffs(
    tiff_path::String; 
    tiff_data::Dict{Int64, Dict{Int64, NamedTuple}}, 
    mapped_data::Dict{Int64, Dict{Int64, NamedTuple}},
    ppage_dict::Dict{Int64, NTuple{2, Int64}},
    processed_assn_data::Dict{Int64, Dict{String, Any}},
    output_dir::String,
)::Nothing
    marked_frames = Tuple{Int64, AbstractArray{UInt8, 3}}[]
    scan_results = Dict{String, Any}[]
    ret, pages = cv.imreadmulti(tiff_path; flags=cv.IMREAD_COLOR)
    if !ret
        error("Could not load TIFF file at $tiff_path")
    end
    printstyled("Annotating Pages\n"; bold=true, underline=true)
    if isdir(output_dir)
        rm(output_dir, recursive=true)
        println("The folder $output_dir already existed, so it was deleted.")
    end
    mkdir(output_dir)
    current_assn_id = nothing
    for (ppage_indx, frame_cv) in enumerate(pages)
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
            
            if isnothing(current_assn_id)
                current_assn_id = assn_id
                println("- Assn $current_assn_id...")
            elseif assn_id != current_assn_id
                save_annotated_assn(marked_frames, current_assn_id; output_dir, scan_results)
                current_assn_id = assn_id
                println("- Assn $current_assn_id...")
            end
            for a in tiff_data[assn_id][page].tiff_anchors
                cv.drawMarker(frame_cv, cv.Point{Int32}(round(Int32, a[1]), round(Int32, a[2])), blue, markerType=cv.MARKER_SQUARE, markerSize=25, thickness=3)
            end
            place_text("Assn ID $assn_id, Page $page", frame_cv; w, h, text_color=(155, 12, 30), pad_right_corner=true)
            mapped_nt = mapped_data[assn_id][page]
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
            push!(marked_frames, (ppage_indx, frame_cv))
        else
            if !isnothing(current_assn_id)
                save_annotated_assn(marked_frames, current_assn_id; output_dir, scan_results)
                current_assn_id = nothing
            end
            push!(scan_results, page_info)
            push!(marked_frames, (ppage_indx, frame_cv))
        end
    end
    save_annotated_assn(marked_frames, current_assn_id; output_dir, scan_results)
    
    # Save scan_results.json
    open(joinpath(output_dir, "scan_results.json"), "w") do f
        JSON.print(f, scan_results)
    end
    return nothing
end

const NAME_BOX_WARP_WIDTH = 539 # original box is 200ptx40pt with 2pt inset, so scale by 2.75
const NAME_BOX_WARP_HEIGHT = 99
# Typst name field is 200pt x 55pt at 2.75x (line 13pt above the bottom).
const NAME_FIELD_WARP_WIDTH = 550
const NAME_FIELD_WARP_HEIGHT = 151

# Same rule as feedback.typ / GoogleDrive.sanitize_student_name.
function _sanitize_training_student_name(name::AbstractString)::String
    return lowercase(replace(String(name), ", " => "_"))
end

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

"""
If any assignment in `processed_assn_data` has `name_box_corners`, write
`[class_name]_name_training_data/` next to the `.assn` with per-student folders of
warped 200×40 name-box crops from the annotated scans.

Returns the output directory, or `nothing` when there is nothing to export.
`class_name` falls back to the archive stem when not provided.
"""
function export_name_training_data(;
    processed_assn_data_file::String,
    grading_data_file::String,
    annotated_scan_folder::String,
    archive_path::String,
    class_name::Union{Nothing, AbstractString}=nothing,
)::Union{String, Nothing}
    @assert isfile(processed_assn_data_file) "Missing processed_assn_data.json: $processed_assn_data_file"
    @assert isfile(grading_data_file) "Missing grading_data.json: $grading_data_file"
    @assert isdir(annotated_scan_folder) "Missing annotated scan folder: $annotated_scan_folder"

    processed = JSON.parsefile(processed_assn_data_file)
    has_name_boxes = any(
        entry -> isa(entry, AbstractDict) && haskey(entry, "name_box_corners"),
        values(processed),
    )
    has_name_boxes || return nothing

    grading = JSON.parsefile(grading_data_file)
    scan_results_path = joinpath(annotated_scan_folder, "scan_results.json")
    scan_results = isfile(scan_results_path) ? JSON.parsefile(scan_results_path) : Any[]

    page_image = Dict{Tuple{Int64, Int64}, String}()
    for res in scan_results
        isa(res, AbstractDict) || continue
        get(res, "identified", false) || continue
        haskey(res, "assn_id") && haskey(res, "page") && haskey(res, "image_path") || continue
        page_image[(Int64(res["assn_id"]), Int64(res["page"]))] = String(res["image_path"])
    end

    cname = if class_name !== nothing && !isempty(strip(String(class_name)))
        strip(String(class_name))
    else
        first(splitext(basename(archive_path)))
    end
    output_dir = joinpath(dirname(abspath(archive_path)), "$(cname)_name_training_data")
    if isdir(output_dir)
        rm(output_dir; recursive=true)
        println("The folder $output_dir already existed, so it was deleted.")
    end
    mkdir(output_dir)

    page_cache = Dict{String, Any}()
    n_students = 0
    n_crops = 0

    for assn_id_str in sort!(collect(keys(processed)); by=string)
        entry = processed[assn_id_str]
        isa(entry, AbstractDict) || continue
        haskey(entry, "name_box_corners") || continue
        nbc = entry["name_box_corners"]
        isa(nbc, AbstractDict) || continue
        haskey(nbc, "page") && haskey(nbc, "positions") || continue

        assn_id = tryparse(Int64, string(assn_id_str))
        assn_id === nothing && continue
        gentry = get(grading, string(assn_id), nothing)
        isa(gentry, AbstractDict) || continue
        name = get(gentry, "name", nothing)
        (isa(name, AbstractString) && !isempty(strip(name))) || continue

        page = Int64(nbc["page"])
        positions = nbc["positions"]
        isa(positions, AbstractVector) || continue
        isempty(positions) && continue
        length(positions) % 4 == 0 || throw(ArgumentError(
            "name_box_corners.positions length must be divisible by 4 for assn $assn_id; got $(length(positions))"
        ))

        img_rel = get(page_image, (assn_id, page), nothing)
        if img_rel === nothing
            img_rel = joinpath("assn_$assn_id", string(lpad(page, 4, '0'), ".png"))
        end
        img_path = joinpath(annotated_scan_folder, img_rel)
        isfile(img_path) || throw(ArgumentError("Annotated scan not found for assn $assn_id page $page: $img_path"))

        image = get!(page_cache, img_path) do
            cv.imread(img_path)
        end

        student_dir = joinpath(output_dir, _sanitize_training_student_name(name))
        mkpath(student_dir)

        n_boxes = length(positions) ÷ 4
        for i in 1:n_boxes
            chunk = positions[(4i - 3):(4i)]
            warped = warp_name_box_crop(image, chunk)
            out_path = joinpath(student_dir, string(lpad(i, 2, '0'), ".png"))
            cv.imwrite(out_path, warped)
            n_crops += 1
        end
        n_students += 1
    end

    if n_students == 0
        rm(output_dir; recursive=true, force=true)
        println("No named students with name_box_corners; skipped name training data export.")
        return nothing
    end

    println("Created: $output_dir ($n_students student folder(s), $n_crops name-box image(s))")
    return output_dir
end

function process_scans(
    tiff_path::String;
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
    with_archive_dir(assn_archive_file) do archive_dir
        page_elements_file = joinpath(archive_dir, "page_elements.json")
        @assert isfile(page_elements_file) "Missing page_elements.json in assnversions archive: $assn_versions_file"
        annotated_dir = joinpath(archive_dir, "annotated")
        tiff_data, ppage_dict = extract_tiff_data(tiff_path; corrections)
        mapped_data, page_elements_data = get_mapped_data(; tiff_data, page_elements_file)
        assn_data = get_question_info_by_assn(tiff_path; mapped_data, page_elements_data, ppage_dict)
        processed_assn_data = process_assn_data(assn_data; mapped_data, output_dir=archive_dir)
        if namereader_file !== nothing && !isempty(strip(String(namereader_file)))
            apply_name_reader_guesses!(
                processed_assn_data;
                tiff_path,
                ppage_dict,
                mapped_data,
                archive_dir,
                namereader_file=String(namereader_file),
            )
        end
        generate_marked_tiffs(tiff_path; ppage_dict, tiff_data, mapped_data, processed_assn_data, output_dir=annotated_dir)
        make_archive_from_dir(archive_dir, assn_archive_file)
        println("Updated: $assn_archive_file (added processed_assn_data.json and annotated scans)")
        stale_tmp = abspath(assn_archive_file) * ".tmp"
        if isdir(stale_tmp)
            rm(stale_tmp; recursive=true, force=true)
            println("Removed stale extract: $stale_tmp")
        end
    end
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
    extract_name_field_crops(tiff_path, processed_assn_data; kwargs...)
    extract_name_field_crops(pages, processed_assn_data; kwargs...)

Warp each assignment's printed name field to the 550×151 canvas used by NameReader.

TIFF page → assignment mapping (first match wins):
- `ppage_of[(assn_id, page)] = tiff_page` if provided
- else decode datamatrices when `decode_datamatrix=true`
- else `assn_page_order[i]` is the assignment id on 1-based TIFF page `i`

Each result is `(; assn_id, page, tiff_page, crop)` with `crop` a `(height, width)`
`Float32` grayscale image in `[0, 1]`.
"""
function extract_name_field_crops(
    tiff_path::String,
    processed_assn_data;
    ppage_of::Union{Nothing,AbstractDict}=nothing,
    assn_page_order::Union{Nothing,AbstractVector{<:Integer}}=nothing,
    decode_datamatrix::Bool=false,
)
    return extract_name_field_crops(
        load_binary_pages(tiff_path),
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
    tiff_path::String,
    ppage_dict::Dict{Int64, NTuple{2, Int64}},
    mapped_data,
    archive_dir::String,
    namereader_file::String,
)
    isfile(namereader_file) || throw(ArgumentError("`.namereader` file not found: $namereader_file"))
    bundle = load_name_reader(namereader_file)
    page_of = Dict{Tuple{Int64,Int64}, Int}()
    for (ppage, (assn_id, page)) in pairs(ppage_dict)
        page_of[(assn_id, page)] = ppage
    end

    extracted = extract_name_field_crops(tiff_path, processed_assn_data; ppage_of=page_of)
    if isempty(extracted)
        println("NameReader: no name-field crops found (assignments need the Typst name-line marks).")
        return processed_assn_data
    end

    crops = [item.crop for item in extracted]
    roster = _archive_roster_names(archive_dir)
    guesses = guess_assignment_names(bundle, crops; roster=roster, allow_unassigned=true)
    name_guesses = Dict{String, String}()
    assigned = 0
    for guess in guesses
        assn_id = extracted[guess.index].assn_id
        if guess.label !== nothing
            name_guesses[string(assn_id)] = match_label_to_roster(guess.label, roster)
            assigned += 1
        end
    end
    guess_path = joinpath(archive_dir, "name_guesses.json")
    open(guess_path, "w") do f
        JSON.print(f, name_guesses)
    end
    println("NameReader: guessed $assigned / $(length(crops)) name(s); wrote name_guesses.json")
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

# Utility helpers included into Server (same scope as routes: HTTP, JSON, CSV, STATE).

function _print_friendly_error(err; bt=nothing)::Nothing
    println("Error:")
    msg = isnothing(bt) ? sprint(showerror, err) : sprint(showerror, err, bt)
    for line in split(msg, '\n')
        println("  " * line)
    end
    return nothing
end

function _optional_path(value)::Union{Nothing,String}
    isa(value, AbstractString) || return nothing
    stripped = strip(String(value))
    return isempty(stripped) ? nothing : stripped
end

function _required_positive_int(value, label::AbstractString)::Int
    isa(value, Real) && isfinite(value) && isinteger(value) && value >= 1 ||
        throw(ArgumentError("`$label` must be a whole number of at least 1, got $(repr(value))"))
    return Int(value)
end

function _required_nonnegative_number(value, label::AbstractString)::Float64
    isa(value, Real) && isfinite(value) && value >= 0 ||
        throw(ArgumentError("`$label` must be a number of at least 0, got $(repr(value))"))
    return Float64(value)
end

"""
User-facing message for Google Drive API failures. Network blips become a short retry hint
instead of a raw HTTP.Exceptions.ConnectError stack dump.
"""
function _friendly_drive_error(err)::String
    msg = sprint(showerror, err)
    lower = lowercase(msg)
    if occursin("ehostunreach", lower) ||
       occursin("enetunreach", lower) ||
       occursin("econnrefused", lower) ||
       occursin("econnreset", lower) ||
       occursin("etimedout", lower) ||
       occursin("timed out", lower) ||
       occursin("host is unreachable", lower) ||
       occursin("nodename nor servname", lower) ||
       occursin("name or service not known", lower) ||
       occursin("connecterror", lower) ||
       occursin("could not resolve host", lower) ||
       occursin("network is unreachable", lower) ||
       occursin("temporary failure in name resolution", lower)
        return "Internet connection looks unstable or Google Drive is unreachable. Check your connection and try again."
    end
    return msg
end

# Compile per-student feedback PDFs via Typst's experimental bundle export into `output_dir`.
function compile_feedback_bundle(;
    grading_data_file::String,
    annotated_scan_folder::String,
    output_dir::String,
)::Nothing
    @assert isfile(grading_data_file) "grading data file not found: $grading_data_file"
    @assert isdir(annotated_scan_folder) "annotated scan folder not found: $annotated_scan_folder"
    if isdir(output_dir)
        rm(output_dir; recursive=true)
        println("The folder $output_dir already existed, so it was deleted.")
    end
    counts_file = joinpath(dirname(abspath(annotated_scan_folder)), "assn_page_counts.json")
    ProcessScans.write_assn_page_counts(annotated_scan_folder)
    @assert isfile(counts_file) "assn_page_counts.json not found next to annotated scans"
    # Typst stdin compile resolves json()/image() paths relative to CWD; absolute paths get
    # mis-joined onto the project root (e.g. /Users/... → <cwd>/Users/...).
    typst_compile_feedback_bundle(;
        grading_data_file=replace(relpath(grading_data_file), "\\" => "/"),
        annotated_scan_folder=replace(relpath(annotated_scan_folder), "\\" => "/"),
        assn_page_counts_file=replace(relpath(counts_file), "\\" => "/"),
        output_dir=abspath(output_dir),
    )
    return nothing
end

function _name_guess_for_assn(name_guesses, assn_id)::Union{Nothing, String}
    isa(name_guesses, AbstractDict) || return nothing
    raw = get(name_guesses, string(assn_id), get(name_guesses, assn_id, nothing))
    isa(raw, AbstractString) || return nothing
    stripped = strip(String(raw))
    return isempty(stripped) ? nothing : stripped
end

function _read_file_from_temp(file_name::String; give_default::Bool=false)::Union{Dict,NamedTuple,AbstractVector}
    temp_dir = STATE["temp_archive_dir"]
    @assert !isnothing(temp_dir) "Temp archive directory not initialized"
    target_file = joinpath(temp_dir, file_name)
    if !isfile(target_file)
        if give_default
            return Dict()
        else
            error("Expected file $file_name in archive, none found")
        end
    end
    if endswith(lowercase(target_file), ".json")
        return json_parsefile(target_file)
    elseif endswith(lowercase(target_file), ".csv")
        return CSV.read(target_file, NamedTuple)
    else
        error("Expected file $file_name in archive, but it is not a .json or .csv file")
    end
end

"""
Find the single class roster CSV in a directory (archive root / temp dir).
Returns absolute path, or `nothing` if none. Errors if more than one `.csv` exists.
"""
function find_roster_csv_path(dir::AbstractString)::Union{String, Nothing}
    isdir(dir) || return nothing
    csvs = sort(filter(f -> endswith(lowercase(f), ".csv"), readdir(dir)))
    isempty(csvs) && return nothing
    length(csvs) > 1 && error(
        "Archive directory $(repr(dir)) contains multiple CSV files ($(join(csvs, ", "))); expected at most one class roster CSV."
    )
    return joinpath(dir, csvs[1])
end

function roster_class_name_from_path(csv_path::AbstractString)::String
    return first(splitext(basename(csv_path)))
end

function _required_class_name(value)::String
    name = _optional_path(value)
    name === nothing && throw(ArgumentError("`class_name` is required."))
    isfile(class_csv_path(name)) || throw(ArgumentError("No class named $(repr(name)) is registered."))
    return name
end

# Fresh training runs get the full schedule; a fine-tune starts from weights that already
# work, so it only needs enough epochs to absorb the new samples.
const TRAIN_EPOCHS = 40
const FINE_TUNE_EPOCHS = 15

"""
Compare rosters by their parsed rows rather than their bytes, so a re-export with
different column order, quoting, or line endings does not read as a change.
"""
function _roster_signature(csv_path::AbstractString)::Union{Nothing, Vector{NTuple{4, String}}}
    table = try
        read_roster_table(csv_path)
    catch
        return nothing
    end
    cell(column, index) = begin
        haskey(table, column) || return ""
        value = getproperty(table, column)[index]
        (ismissing(value) || value === nothing) ? "" : strip(string(value))
    end
    return [
        (cell(:Student, i), cell(:ID, i), cell(:Section, i), cell(:Email, i))
        for i in eachindex(table.Student)
    ]
end

"""
    roster_sync_status(archive_csv_path)

Whether the roster inside an archive still matches the app's class of the same
name. `differs` is only meaningful when `app_roster_exists` and both files parse.
"""
function roster_sync_status(archive_csv_path::Union{Nothing, AbstractString})::Dict{String, Any}
    if archive_csv_path === nothing
        return Dict{String, Any}("class_name" => nothing, "app_roster_exists" => false, "differs" => false)
    end
    class_name = roster_class_name_from_path(archive_csv_path)
    app_csv = try
        class_csv_path(class_name)
    catch
        return Dict{String, Any}("class_name" => class_name, "app_roster_exists" => false, "differs" => false)
    end
    if !isfile(app_csv)
        return Dict{String, Any}("class_name" => class_name, "app_roster_exists" => false, "differs" => false)
    end
    archive_rows = _roster_signature(archive_csv_path)
    app_rows = _roster_signature(app_csv)
    differs = archive_rows === nothing || app_rows === nothing ?
        read(archive_csv_path, String) != read(app_csv, String) :
        archive_rows != app_rows
    return Dict{String, Any}(
        "class_name" => class_name,
        "app_roster_exists" => true,
        "app_roster_path" => app_csv,
        "archive_roster_path" => String(archive_csv_path),
        "differs" => differs,
        "app_num_students" => app_rows === nothing ? nothing : length(app_rows),
        "archive_num_students" => archive_rows === nothing ? nothing : length(archive_rows),
    )
end

"""
The archive's single top-level roster CSV entry name, or `nothing` when there is
not exactly one.
"""
function archive_roster_entry_name(archive_path::AbstractString)::Union{Nothing, String}
    entries = try
        archive_entry_names(archive_path)
    catch
        return nothing
    end
    csvs = sort(filter(entries) do name
        endswith(lowercase(name), ".csv") && !occursin('/', name) && !startswith(name, ".")
    end)
    return length(csvs) == 1 ? csvs[1] : nothing
end

"""
    archive_roster_status(archive_path)

`roster_sync_status` for an `.assn` / `.assnversions` file, reading just the
roster entry out of the archive rather than unpacking all of it.
"""
function archive_roster_status(archive_path::AbstractString)::Dict{String, Any}
    entry = archive_roster_entry_name(archive_path)
    entry === nothing &&
        return Dict{String, Any}("class_name" => nothing, "app_roster_exists" => false, "differs" => false)
    return mktempdir() do dir
        dest = joinpath(dir, basename(entry))
        extract_archive_entry(archive_path, entry, dest) === nothing &&
            return Dict{String, Any}("class_name" => nothing, "app_roster_exists" => false, "differs" => false)
        status = roster_sync_status(dest)
        status["archive_roster_path"] = String(archive_path)
        return status
    end
end

"""
Copy the app's class roster over the one in an unpacked archive directory, keeping
the archive's file name so the archive never ends up with two rosters.
"""
function apply_app_roster_to_dir(archive_dir::AbstractString)::Dict{String, Any}
    archive_csv = find_roster_csv_path(archive_dir)
    archive_csv === nothing && throw(ArgumentError("This archive has no class roster CSV to update."))
    status = roster_sync_status(archive_csv)
    status["app_roster_exists"] || throw(ArgumentError(
        "No class named $(repr(status["class_name"])) is registered in the app."
    ))
    cp(status["app_roster_path"], archive_csv; force=true)
    return status
end

function _read_roster_from_temp(; give_default::Bool=false)
    temp_dir = STATE["temp_archive_dir"]
    @assert !isnothing(temp_dir) "Temp archive directory not initialized"
    path = find_roster_csv_path(temp_dir)
    if path === nothing
        give_default && return nothing
        error("Expected a class roster CSV in the archive, none found")
    end
    return (path=path, class_name=roster_class_name_from_path(path), table=read_roster_table(path))
end

function _score_from_answer(
    q_type::String,
    detected_answer::Union{Integer,AbstractString,AbstractVector},
    correct_answer::Union{Nothing,Integer,AbstractString,AbstractVector},
    points::Real,
)::Float64
    # Missing/null correct_answer on MC/TF → participation credit.
    if isnothing(correct_answer)
        if q_type == "multiple_choice"
            return isa(detected_answer, Integer) ? Float64(points) : 0.0
        end
        if q_type == "true_false"
            @assert isa(detected_answer, AbstractVector) "`detected_answer` for true_false question was not a vector"
            return all(a -> isa(a, Bool), detected_answer) ? Float64(points) : 0.0
        end
        return 0.0
    end
    if q_type == "multiple_choice"
        return detected_answer == correct_answer ? points : 0.0
    end
    if q_type == "true_false"
        @assert isa(detected_answer, AbstractVector) "`detected_answer` for true_false question was not a vector"
        correct_count = 0
        for (i, ans) in enumerate(detected_answer)
            expected_true = (i - 1) ∈ correct_answer
            if ans === expected_true
                correct_count += 1
            end
        end
        return (correct_count / length(detected_answer)) * points
    end
    return 0.0
end

function _build_grading_data_from_archive()::Dict{Int64, Dict{String, Any}}
    processed = _read_file_from_temp("processed_assn_data.json")
    master = _read_file_from_temp("master.json")
    selection = _read_file_from_temp("selection.json")
    page_elements = _read_file_from_temp("page_elements.json"; give_default=true)
    var_answers = _read_file_from_temp("var_answers.json"; give_default=true)
    name_guesses = _read_file_from_temp("name_guesses.json"; give_default=true)
    grading_data = Dict{Int64, Dict{String, Any}}()

    function flatten_master_questions(questions::AbstractVector, path::String="")::Vector{Dict{String, Any}}
        results = Vector{Dict{String, Any}}()
        for (i, q) in enumerate(questions)
            indx0 = i - 1 # shifted for zero-indexing
            q_path = isempty(path) ? string(indx0) : string(path, ".", indx0)
            if isa(q, Dict) && haskey(q, "questions")
                append!(results, flatten_master_questions(q["questions"], q_path))
            else
                q["id"] = "q" * q_path
                push!(results, q)
            end
        end
        return results
    end

    function flatten_selection_questions(questions::AbstractVector, path::String="")::Vector{Dict{String, Any}}
        results = Vector{Dict{String, Any}}()
        for q in questions
            q_indx = if isa(q, Int64)
                q
            elseif isa(q, Dict)
                @assert haskey(q, "indx") "question dictionary missing indx field in selection json"
                get(q, "indx", -1)
            else
                error("question is neither int nor object in selection json")
            end
            q_path = isempty(path) ? string(q_indx) : string(path, ".", q_indx)
            if isa(q, Dict) && haskey(q, "questions")
                append!(results, flatten_selection_questions(q["questions"], q_path))
            elseif isa(q, Int64)
                push!(results, Dict("id" => "q" * q_path))
            else
                q["id"] = "q" * q_path
                push!(results, q)
            end
        end
        return results
    end

    function adjusted_correct_answer(master_q::Dict, version_node::Dict)
        master_ca = get(master_q, "correct_answer", nothing)
        if isnothing(master_ca)
            return nothing
        end
        q_type = String(master_q["type"])
        if q_type == "true_false"
            @assert isa(master_ca, AbstractVector) "master correct answer for true_false question must be a vector, got $(typeof(master_ca))"
            @assert all(_is_json_int, master_ca) "master correct answer for true_false question must be vector of integers, got $(typeof(master_ca))"
            master_ca = _as_int64_vector(master_ca)
        elseif q_type == "multiple_choice"
            @assert isa(master_ca, Integer) || _is_json_int(master_ca) "master correct answer for multiple_choice question must be integer, got $(typeof(master_ca))"
            master_ca = Int64(master_ca)
        end
        perm = get(version_node, "option_permutation", nothing)
        if isnothing(perm) || !isa(perm, AbstractVector)
            return master_ca
        end
        perm = Int64.(perm)
        if q_type == "multiple_choice"
            pos = findfirst(==(master_ca), perm)
            @assert !isnothing(pos) "correct answer index missing from permutation"
            return pos - 1 # convert to zero-indexing
        elseif q_type == "true_false"
            master_true = Set(master_ca)
            adjusted = Int64[]
            for (i, orig_indx) in enumerate(perm)
                if orig_indx in master_true
                    push!(adjusted, i - 1) # convert to zero-indexing
                end
            end
            return adjusted
        end
        return master_ca
    end

    function attach_master_answer!(q_entry::Dict, master_q::Dict, version_node::Dict)
        q_type = String(get(master_q, "type", ""))
        (q_type == "multiple_choice" || q_type == "true_false") || return
        nopts = if haskey(master_q, "options")
            length(master_q["options"])
        elseif haskey(master_q, "func_options")
            length(master_q["func_options"])
        else
            return
        end
        nopts > 0 || return
        perm = get(version_node, "option_permutation", nothing)
        identity = collect(0:(nopts - 1))
        if isnothing(perm) || !isa(perm, AbstractVector) || length(perm) != nopts
            perm = identity
        else
            perm = Int64.(perm)
        end
        # Omit identity permutations; readers treat missing as 0..n-1.
        if perm != identity
            q_entry["option_permutation"] = perm
        end
        ans = get(q_entry, "answer", nothing)
        if q_type == "multiple_choice"
            if ans == "unanswered" || ans == "unknown"
                q_entry["master_answer"] = ans
            elseif isa(ans, Integer)
                idx = Int64(ans) + 1
                @assert 1 <= idx <= nopts "MC answer index out of range"
                q_entry["master_answer"] = perm[idx]
            end
        elseif q_type == "true_false" && isa(ans, AbstractVector)
            selected = Vector{Any}(undef, nopts)
            fill!(selected, "unanswered")
            for (k, v) in enumerate(ans)
                selected[perm[k] + 1] = v
            end
            q_entry["master_answer"] = selected
        end
        return nothing
    end

    # make master lookup: key is question id, value is question
    @assert haskey(master, "questions") "master json is missing \"questions\" field"
    all_master_questions = flatten_master_questions(master["questions"])
    master_lookup = Dict{String, Dict}()
    for q in all_master_questions
        master_lookup[q["id"]] = q
    end
    # make selection lookup: key is assn index, value is version dictionary
    selection_lookup = Dict{Int64, Dict}()
    @assert haskey(selection, "versions") && isa(selection["versions"], AbstractVector) "selection json is missing \"versions\" field that is an array"
    for ver in selection["versions"]
        @assert isa(ver, Dict) "one version was not a dictionary in \"versions\" within selection json"
        # The answer-key entry has is_key=true and no assn_id; only student versions are graded.
        if Bool(get(ver, "is_key", false))
            continue
        end
        @assert haskey(ver, "assn_id") "student version in selection json is missing assn_id"
        @assert haskey(ver, "questions") "version in selection json is missing questions"
        selection_lookup[Int64(ver["assn_id"])] = ver
    end
    # collect information for version questions
    for (assn_id, processed_entry) in pairs(processed)
        assn_id_int = parse(Int64, assn_id)
        assn_version = get(selection_lookup, assn_id_int, nothing)
        @assert !isnothing(assn_version) "assn version not found for assn id $assn_id"
        selection_version_all_questions = flatten_selection_questions(assn_version["questions"])
        processed_questions = begin
            @assert isa(processed_entry, AbstractDict) "processed_assn_data entry for assn id $assn_id must be an object"
            @assert haskey(processed_entry, "questions") "processed_assn_data entry for assn id $assn_id is missing `questions`"
            _pad_processed_questions_for_missing_pages(
                processed_entry["questions"],
                assn_id_int,
                page_elements,
            )
        end
        @assert length(selection_version_all_questions) == length(processed_questions) "discrepancy in number of questions between processed json and selection json for assn id $assn_id"
        # collect information from processed json and correct answer from master + selection jsons
        for (i, sel_ver_q) in enumerate(selection_version_all_questions)
            q_entry = processed_questions[i]
            @assert isa(q_entry, Dict) "found question in processed json that is not an object for assn id $assn_id"
            # Scan-internal fields: keep q_height for UI scroll positioning; drop the rest.
            delete!(q_entry, "bubble_densities")
            delete!(q_entry, "left_bubble_positions")
            q_id = q_entry["id"] = sel_ver_q["id"]
            @assert haskey(master_lookup, q_id) "master lookup expected to have key $q_id, but it is missing"
            master_q = master_lookup[q_id]
            ca = adjusted_correct_answer(master_q, sel_ver_q)
            if !isnothing(ca)
                q_entry["correct_answer"] = ca
            end
            attach_master_answer!(q_entry, master_q, sel_ver_q)
            is_without_points = !haskey(master_q, "points")
            is_pregraded = haskey(q_entry, "answer") && (
                (master_q["type"] == "multiple_choice" && (isa(q_entry["answer"], Integer) || q_entry["answer"] == "unanswered")) ||
                (master_q["type"] == "true_false" && all(i -> isa(i, Bool) || i == "unanswered", q_entry["answer"]))
            )
            if !is_without_points
                q_entry["max_points"] = master_q["points"]
            end
            if is_without_points || is_pregraded
                q_entry["is_graded"] = true
            end
            if is_pregraded && !is_without_points
                q_entry["points"] = _score_from_answer(
                    master_q["type"],
                    q_entry["answer"],
                    ca,
                    master_q["points"],
                )
            end
        end
        # collect information from var_answers json
        ver_var_answers = get(var_answers, assn_id, Dict())
        @assert isa(ver_var_answers, Dict) "var_answers json value for assn_id $assn_id is not an object"
        for (q_indx, answers) in pairs(ver_var_answers)
            q_indx_int = parse(Int64, q_indx) + 1 # shift from zero-indexing
            processed_questions[q_indx_int]["var_answer"] = answers
        end
        # save questions for version
        entry = Dict{String, Any}("questions" => processed_questions)
        guessed = _name_guess_for_assn(name_guesses, assn_id_int)
        if guessed !== nothing
            entry["name"] = guessed
            entry["name_guessed"] = true
        end
        grading_data[assn_id_int] = entry
    end
    return grading_data
end

function _pad_processed_questions_for_missing_pages(processed_questions, assn_id_int::Int64, page_elements)::Vector
    isa(processed_questions, AbstractVector) || return processed_questions
    pe = get(page_elements, string(assn_id_int), nothing)
    pe === nothing && return processed_questions
    by_page = Dict{Int64, Vector{Any}}()
    for q in processed_questions
        isa(q, AbstractDict) && haskey(q, "page") || continue
        push!(get!(() -> Any[], by_page, Int64(q["page"])), q)
    end
    out = Any[]
    for page in sort!(parse.(Int64, collect(keys(pe))))
        page_elems = get(pe, string(page), Dict())
        n_expected = length(get(page_elems, "q_heights", []))
        have = get(by_page, page, nothing)
        if have === nothing || isempty(have)
            for _ in 1:n_expected
                push!(out, Dict{String, Any}("page" => page))
            end
        else
            append!(out, have)
        end
    end
    return out
end

function _flatten_master_questions_export(questions::AbstractVector, path::String="")::Vector{Dict{String, Any}}
    results = Vector{Dict{String, Any}}()
    for (i, q) in enumerate(questions)
        indx0 = i - 1
        q_path = isempty(path) ? string(indx0) : string(path, ".", indx0)
        if isa(q, Dict) && haskey(q, "questions")
            append!(results, _flatten_master_questions_export(q["questions"], q_path))
        elseif isa(q, Dict)
            q = copy(q)
            q["id"] = "q" * q_path
            push!(results, q)
        end
    end
    return results
end

function _format_tf_pattern(nopts::Int, true_indices)::String
    true_set = Set{Int64}(Int64.(true_indices))
    return join([i in true_set ? "T" : "F" for i in 0:(nopts - 1)], ",")
end

function _format_master_answer_cell(q_type::String, master_answer)::String
    if q_type == "multiple_choice"
        return isa(master_answer, Integer) ? string(master_answer) : "NA"
    elseif q_type == "true_false"
        if !isa(master_answer, AbstractVector)
            return "NA"
        end
        parts = String[]
        for v in master_answer
            if v === true || v == true
                push!(parts, "T")
            elseif v === false || v == false
                push!(parts, "F")
            else
                push!(parts, "NA")
            end
        end
        return join(parts, ",")
    end
    return "NA"
end

function _answer_column_header(master_q::Dict)::String
    qid = string(master_q["id"])
    q_type = string(get(master_q, "type", ""))
    ca = get(master_q, "correct_answer", nothing)
    if isnothing(ca)
        return "$qid - answer"
    end
    if q_type == "multiple_choice" && isa(ca, Integer)
        return "$qid - answer:$ca"
    elseif q_type == "true_false"
        nopts = if haskey(master_q, "options")
            length(master_q["options"])
        elseif haskey(master_q, "func_options")
            length(master_q["func_options"])
        elseif isa(ca, AbstractVector) && !isempty(ca)
            maximum(Int64.(ca)) + 1
        else
            0
        end
        nopts > 0 || return "$qid - answer"
        return "$qid - answer:" * _format_tf_pattern(nopts, ca)
    end
    return "$qid - answer"
end

function _entry_total_points(entry::Dict)::Union{Float64, Missing}
    if haskey(entry, "total_points") && isa(entry["total_points"], Number)
        return Float64(entry["total_points"])
    end
    total = 0.0
    has_any = false
    for q in get(entry, "questions", Any[])
        isa(q, Dict) || continue
        pts = get(q, "points", nothing)
        if isa(pts, Number)
            total += Float64(pts)
            has_any = true
        end
    end
    return has_any ? total : missing
end

function _assignment_max_points(master::Dict)::Union{Float64, Missing}
    total = 0.0
    has_any = false
    for mq in _flatten_master_questions_export(get(master, "questions", Any[]))
        pts = get(mq, "points", nothing)
        if isa(pts, Number)
            total += Float64(pts)
            has_any = true
        end
    end
    return has_any ? total : missing
end

function _csv_field(value)::String
    (value === missing || value === nothing) && return ""
    s = string(value)
    if occursin(r"[\",\n\r]", s) || startswith(s, " ") || endswith(s, " ")
        return "\"" * replace(s, "\"" => "\"\"") * "\""
    end
    return s
end

function _csv_number_field(value)::String
    (value === missing || value === nothing) && return ""
    if isa(value, Integer)
        return string(value)
    elseif isa(value, AbstractFloat) && isfinite(value) && isinteger(value)
        return string(Int64(value))
    end
    return string(value)
end

const ASSIGNMENT_SCORES_HEADER = "Assignment Scores"
const POINTS_POSSIBLE_CELL = "    Points Possible"

function _canvas_assignment_column_name(master::Dict)::String
    raw = strip(string(get(master, "title", ASSIGNMENT_SCORES_HEADER)))
    isempty(raw) && return ASSIGNMENT_SCORES_HEADER
    cleaned = replace(raw, r"[^A-Za-z0-9 (){}\[\]/\-]" => "")
    cleaned = strip(replace(cleaned, r" +" => " "))
    return isempty(cleaned) ? ASSIGNMENT_SCORES_HEADER : cleaned
end

# Canvas-style non-detailed scores CSV: Student, optional ID, optional Section, assignment title,
# plus a "    Points Possible" row under the header. Email is never included.
function _write_canvas_scores_csv(
    path::String,
    rows::Vector{Dict{String, Any}},
    has_id::Bool,
    has_section::Bool,
    score_header::String,
    max_points::Union{Float64, Missing},
)::Nothing
    headers = String["Student"]
    has_id && push!(headers, "ID")
    has_section && push!(headers, "Section")
    push!(headers, score_header)
    open(path, "w") do io
        println(io, join(headers, ","))
        max_cell = _csv_number_field(max_points)
        pp_cells = String[POINTS_POSSIBLE_CELL]
        has_id && push!(pp_cells, "")
        has_section && push!(pp_cells, "")
        push!(pp_cells, max_cell)
        println(io, join(pp_cells, ","))
        for row in rows
            cells = String[_csv_field(get(row, "Student", missing))]
            has_id && push!(cells, _csv_field(get(row, "ID", missing)))
            has_section && push!(cells, _csv_field(get(row, "Section", missing)))
            push!(cells, _csv_number_field(get(row, score_header, missing)))
            println(io, join(cells, ","))
        end
    end
    return nothing
end

function _write_csv_rows(path::String, headers::Vector{String}, rows::Vector{Dict{String, Any}})::Nothing
    col_syms = Tuple(Symbol(h) for h in headers)
    if isempty(rows)
        # Header-only file.
        open(path, "w") do io
            println(io, join(headers, ","))
        end
        return nothing
    end
    named_rows = [
        NamedTuple{col_syms}(Tuple(get(row, h, missing) for h in headers))
        for row in rows
    ]
    CSV.write(path, named_rows)
    return nothing
end

function detailed_scores_csv_path(archive_path::AbstractString)::String
    stem = first(splitext(basename(archive_path)))
    return joinpath(dirname(archive_path), "$(stem)_scores_detailed.csv")
end

function scores_csv_path(archive_path::AbstractString)::String
    stem = first(splitext(basename(archive_path)))
    return joinpath(dirname(archive_path), "$(stem)_scores.csv")
end

# Write `_scores_detailed.csv` and `_scores.csv` next to the loaded .assn archive.
# Returns (detailed_path, scores_path).
function export_score_csvs(;
    grading_data::Dict,
    master::Dict,
    students_table::Union{Nothing,NamedTuple},
    archive_path::String,
    class_name::Union{Nothing, AbstractString}=nothing,
)::Tuple{String, String}
    detailed_path = detailed_scores_csv_path(archive_path)
    scores_path = scores_csv_path(archive_path)

    master_qs = _flatten_master_questions_export(get(master, "questions", Any[]))

    # --- detailed CSV ---
    col_specs = Any[]
    question_headers = String[]
    for mq in master_qs
        qid = string(mq["id"])
        q_type = string(get(mq, "type", ""))
        has_points = haskey(mq, "points")
        if q_type == "multiple_choice" || q_type == "true_false"
            ah = _answer_column_header(mq)
            push!(question_headers, ah)
            push!(col_specs, (kind=:answer, qid=qid, header=ah, q_type=q_type))
            if has_points
                sh = "$qid - score"
                push!(question_headers, sh)
                push!(col_specs, (kind=:score, qid=qid, header=sh, q_type=q_type))
            end
        elseif q_type == "essay" || q_type == "fill_blank"
            if has_points
                sh = "$qid - score"
                push!(question_headers, sh)
                push!(col_specs, (kind=:score, qid=qid, header=sh, q_type=q_type))
            end
        end
    end

    detailed_entries = Tuple{String, Int64, Dict}[]  # (name, assn_id, entry)
    for (assn_key, entry) in pairs(grading_data)
        string(assn_key) == "feedback-templates" && continue
        isa(entry, Dict) || continue
        assn_id = try
            Int64(assn_key isa Integer ? assn_key : parse(Int64, string(assn_key)))
        catch
            continue
        end
        name = string(get(entry, "name", ""))
        push!(detailed_entries, (name, assn_id, entry))
    end
    sort!(detailed_entries; by = x -> (lowercase(x[1]), x[2]))

    email_by_name = Dict{String, String}()
    if roster_has_email(students_table) && haskey(students_table, :Student)
        for (rname, email) in zip(students_table.Student, students_table.Email)
            (ismissing(email) || email === nothing) && continue
            es = strip(string(email))
            isempty(es) && continue
            email_by_name[string(rname)] = es
        end
    end
    has_email = !isempty(email_by_name)

    id_by_name = Dict{String, Any}()
    has_id = roster_has_id(students_table) && haskey(students_table, :Student)
    if has_id
        for (rname, id) in zip(students_table.Student, students_table.ID)
            (ismissing(id) || id === nothing) && continue
            id_by_name[string(rname)] = id
        end
    end

    drive_urls = lookup_student_drive_folder_urls(
        class_name,
        (name for (name, _, _) in detailed_entries),
    )
    has_drive = !isempty(drive_urls)

    detailed_headers = String["Student"]
    has_id && push!(detailed_headers, "ID")
    has_email && push!(detailed_headers, "Email")
    has_drive && push!(detailed_headers, "Google Drive")
    push!(detailed_headers, "assn_id")
    append!(detailed_headers, question_headers)
    push!(detailed_headers, "total")

    detailed_rows = Dict{String, Any}[]
    for (name, assn_id, entry) in detailed_entries
        q_by_id = Dict{String, Dict}()
        for q in get(entry, "questions", Any[])
            isa(q, Dict) && haskey(q, "id") || continue
            q_by_id[string(q["id"])] = q
        end
        row = Dict{String, Any}("Student" => name, "assn_id" => assn_id)
        if has_id
            row["ID"] = get(id_by_name, name, missing)
        end
        if has_email
            row["Email"] = get(email_by_name, name, missing)
        end
        if has_drive
            row["Google Drive"] = get(drive_urls, name, missing)
        end
        for spec in col_specs
            q = get(q_by_id, spec.qid, nothing)
            if spec.kind === :answer
                if isnothing(q)
                    row[spec.header] = "NA"
                else
                    row[spec.header] = _format_master_answer_cell(spec.q_type, get(q, "master_answer", nothing))
                end
            else
                pts = isnothing(q) ? nothing : get(q, "points", nothing)
                row[spec.header] = isa(pts, Number) ? pts : missing
            end
        end
        row["total"] = _entry_total_points(entry)
        push!(detailed_rows, row)
    end
    _write_csv_rows(detailed_path, detailed_headers, detailed_rows)

    # --- simplified scores CSV ---
    named_totals = Dict{String, Float64}()
    for (name, _, entry) in detailed_entries
        isempty(name) && continue
        tot = _entry_total_points(entry)
        isa(tot, Number) || continue
        named_totals[name] = Float64(tot)
    end

    scores_rows = Dict{String, Any}[]
    has_id = roster_has_id(students_table)
    has_section = roster_has_section(students_table)
    score_header = _canvas_assignment_column_name(master)
    if !isnothing(students_table) && haskey(students_table, :Student)
        roster_names = string.(students_table.Student)
        roster_ids = has_id ? students_table.ID : nothing
        roster_sections = has_section ? students_table.Section : nothing
        used = Set{String}()
        for (i, rname) in enumerate(roster_names)
            haskey(named_totals, rname) || continue
            push!(used, rname)
            row = Dict{String, Any}("Student" => rname, score_header => named_totals[rname])
            if has_id
                row["ID"] = roster_ids[i]
            end
            if has_section
                row["Section"] = roster_sections[i]
            end
            push!(scores_rows, row)
        end
        for name in sort(collect(keys(named_totals)); by=lowercase)
            name in used && continue
            row = Dict{String, Any}("Student" => name, score_header => named_totals[name])
            if has_id
                row["ID"] = missing
            end
            if has_section
                row["Section"] = missing
            end
            push!(scores_rows, row)
        end
    else
        for name in sort(collect(keys(named_totals)); by=lowercase)
            push!(scores_rows, Dict{String, Any}("Student" => name, score_header => named_totals[name]))
        end
    end

    sort!(scores_rows; by = r -> lowercase(string(r["Student"])))
    _write_canvas_scores_csv(
        scores_path,
        scores_rows,
        has_id,
        has_section,
        score_header,
        _assignment_max_points(master),
    )

    return (detailed_path, scores_path)
end

function _drive_url_for_student_name(name::AbstractString, urls_by_name)::Union{Nothing, String}
    isempty(urls_by_name) && return nothing
    exact = get(urls_by_name, String(name), nothing)
    exact !== nothing && return String(exact)
    key = sanitize_student_name(name)
    isempty(key) && return nothing
    for (n, url) in urls_by_name
        sanitize_student_name(string(n)) == key && return String(url)
    end
    return nothing
end

# Insert or fill the Google Drive column on an existing detailed CSV. Other cells are left as-is.
function update_detailed_csv_drive_links(path::String, urls_by_name)::Nothing
    isfile(path) || throw(ArgumentError("detailed CSV not found: $path"))
    table = CSV.File(path)
    existing_headers = String[string(n) for n in propertynames(table)]
    isempty(existing_headers) && return nothing
    ("Student" in existing_headers) || throw(ArgumentError(
        "detailed CSV is missing a Student column: $path"
    ))

    headers = copy(existing_headers)
    drive_col = "Google Drive"
    if !(drive_col in headers)
        insert_at = if "Email" in headers
            findfirst(isequal("Email"), headers) + 1
        elseif "ID" in headers
            findfirst(isequal("ID"), headers) + 1
        else
            findfirst(isequal("Student"), headers) + 1
        end
        insert!(headers, insert_at, drive_col)
    end

    rows = Dict{String, Any}[]
    for row in table
        d = Dict{String, Any}()
        for h in existing_headers
            d[h] = getproperty(row, Symbol(h))
        end
        url = _drive_url_for_student_name(string(get(d, "Student", "")), urls_by_name)
        if url !== nothing
            d[drive_col] = url
        elseif !haskey(d, drive_col)
            d[drive_col] = missing
        end
        push!(rows, d)
    end
    _write_csv_rows(path, headers, rows)
    return nothing
end

function _coerce_drive_folder_urls(raw)::Dict{String, String}
    urls = Dict{String, String}()
    isa(raw, AbstractDict) || return urls
    for (name, url) in raw
        ns = strip(string(name))
        us = strip(string(url))
        (isempty(ns) || isempty(us)) && continue
        urls[ns] = us
    end
    return urls
end

# After a Drive upload, add folder URLs to the already-written detailed CSV only.
function patch_detailed_csv_drive_links_after_upload(summary)::Nothing
    archive_path = get(STATE, "assn_archive_path", nothing)
    isa(archive_path, AbstractString) && isfile(archive_path) || return nothing
    urls = _coerce_drive_folder_urls(get(summary, "drive_folder_urls", nothing))
    isempty(urls) && return nothing
    path = detailed_scores_csv_path(String(archive_path))
    isfile(path) || return nothing
    update_detailed_csv_drive_links(path, urls)
    return nothing
end

function _resolve_workspace_source_file(raw)::Union{Nothing,String}
    isa(raw, AbstractString) || return nothing
    stripped = strip(String(raw))
    isempty(stripped) && return nothing
    rel = try
        resolve_under_workspace(stripped)
    catch
        return nothing
    end
    abs = abspath(rel)
    return isfile(abs) ? abs : nothing
end

function _preview_work_dir(source_path)::String
    abs_file = _resolve_workspace_source_file(source_path)
    return isnothing(abs_file) ? abspath(pwd()) : dirname(abs_file)
end

function _rel_under(root::String, path::String)::String
    return replace(relpath(abspath(path), abspath(root)), "\\" => "/")
end

function _cleanup_builder_preview_dir!()::Nothing
    preview_dir = get(STATE, "preview_dir", nothing)
    if isa(preview_dir, AbstractString) && isdir(preview_dir)
        try
            rm(preview_dir; force=true, recursive=true)
        catch
        end
    end
    STATE["preview_dir"] = nothing
    STATE["preview_work_dir"] = nothing
    STATE["preview_id"] = nothing
    STATE["question_preview_hash"] = nothing
    return nothing
end

function _ensure_builder_preview_dir!(; source_path=nothing)::Tuple{String,String,String}
    work_dir = _preview_work_dir(source_path)
    preview_dir = get(STATE, "preview_dir", nothing)
    stored_work = get(STATE, "preview_work_dir", nothing)
    if !(isa(preview_dir, AbstractString) && isdir(preview_dir)) || stored_work != work_dir
        if isa(preview_dir, AbstractString) && isdir(preview_dir)
            try
                rm(preview_dir; force=true, recursive=true)
            catch
            end
        end
        preview_dir = mktempdir(work_dir)
        STATE["preview_dir"] = preview_dir
        STATE["preview_work_dir"] = work_dir
        STATE["preview_id"] = string(rand(UInt64), base=16)
        STATE["question_preview_hash"] = nothing
    end
    preview_id = get(STATE, "preview_id", nothing)
    if !isa(preview_id, AbstractString) || isempty(String(preview_id))
        preview_id = string(rand(UInt64), base=16)
        STATE["preview_id"] = preview_id
    end
    return (String(preview_dir), String(preview_id), String(work_dir))
end

function _json_cache_key(obj)::String
    buf = IOBuffer()
    json_print(buf, obj)
    return string(hash(String(take!(buf))), base=16)
end

function _clear_full_preview_pages!(preview_dir::String)::Nothing
    for file_name in readdir(preview_dir)
        if startswith(file_name, "page-") && endswith(file_name, ".png")
            rm(joinpath(preview_dir, file_name); force=true)
        end
    end
    return nothing
end

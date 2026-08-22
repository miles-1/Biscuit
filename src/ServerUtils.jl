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
    # Typst stdin compile resolves json()/image() paths relative to CWD; absolute paths get
    # mis-joined onto the project root (e.g. /Users/... → <cwd>/Users/...).
    typst_compile_feedback_bundle(;
        grading_data_file=replace(relpath(grading_data_file), "\\" => "/"),
        annotated_scan_folder=replace(relpath(annotated_scan_folder), "\\" => "/"),
        output_dir=abspath(output_dir),
    )
    return nothing
end

function _normalize_json_types(x)
    if isa(x, AbstractDict) || isa(x, Dict) || (isdefined(Main, :JSON3) && isa(x, JSON3.Object))
        out = Dict{String, Any}()
        for (k, v) in pairs(x)
            out[String(k)] = _normalize_json_types(v)
        end
        return out
    elseif isa(x, AbstractVector)
        normalized = Any[_normalize_json_types(v) for v in x]
        if all(v -> isa(v, Bool), normalized)
            return Bool.(normalized)
        elseif all(v -> isa(v, Integer), normalized)
            return Int64.(normalized)
        elseif all(v -> isa(v, Real) && isfinite(v) && isinteger(v), normalized)
            return round.(Int64, normalized)
        elseif all(v -> isa(v, AbstractFloat), normalized)
            return Float64.(normalized)
        elseif all(v -> isa(v, AbstractString), normalized)
            return String.(normalized)
        else
            return normalized
        end
    end
    return x
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
        return _normalize_json_types(JSON.parsefile(target_file))
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
        perm = get(version_node, "option_permutation", nothing)
        if isnothing(perm) || !isa(perm, AbstractVector)
            return master_ca
        end
        if q_type == "multiple_choice"
            @assert isa(master_ca, Integer) "master correct answer for multiple_choice question must be integer, got $(typeof(master_ca))"
            pos = findfirst(==(master_ca), perm)
            @assert !isnothing(pos) "correct answer index missing from permutation"
            return pos - 1 # convert to zero-indexing
        elseif q_type == "true_false"
            @assert isa(master_ca, AbstractVector{Int64}) "master correct answer for true_false question must be vector of integers, got $(typeof(master_ca))"
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
            processed_entry["questions"]
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

# Canvas-style non-detailed scores CSV: Student, optional ID, Assignment Scores,
# plus a "    Points Possible" row under the header. Email is never included.
function _write_canvas_scores_csv(
    path::String,
    rows::Vector{Dict{String, Any}},
    has_id::Bool,
    max_points::Union{Float64, Missing},
)::Nothing
    headers = has_id ? String["Student", "ID", ASSIGNMENT_SCORES_HEADER] : String["Student", ASSIGNMENT_SCORES_HEADER]
    open(path, "w") do io
        println(io, join(headers, ","))
        max_cell = _csv_number_field(max_points)
        if has_id
            println(io, POINTS_POSSIBLE_CELL * ",," * max_cell)
        else
            println(io, POINTS_POSSIBLE_CELL * "," * max_cell)
        end
        for row in rows
            name_cell = _csv_field(get(row, "Student", missing))
            score_cell = _csv_number_field(get(row, ASSIGNMENT_SCORES_HEADER, missing))
            if has_id
                println(io, join((name_cell, _csv_field(get(row, "ID", missing)), score_cell), ","))
            else
                println(io, join((name_cell, score_cell), ","))
            end
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

# Write `_detailed_scores.csv` and `_scores.csv` next to the loaded .assn archive.
# Returns (detailed_path, scores_path).
function export_score_csvs(;
    grading_data::Dict,
    master::Dict,
    students_table::Union{Nothing,NamedTuple},
    archive_path::String,
    class_name::Union{Nothing, AbstractString}=nothing,
)::Tuple{String, String}
    stem = first(splitext(basename(archive_path)))
    out_dir = dirname(archive_path)
    detailed_path = joinpath(out_dir, "$(stem)_detailed_scores.csv")
    scores_path = joinpath(out_dir, "$(stem)_scores.csv")

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

    drive_urls = lookup_student_drive_folder_urls(
        class_name,
        (name for (name, _, _) in detailed_entries),
    )
    has_drive = !isempty(drive_urls)

    detailed_headers = String["Student"]
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
    if !isnothing(students_table) && haskey(students_table, :Student)
        roster_names = string.(students_table.Student)
        roster_ids = has_id ? students_table.ID : nothing
        used = Set{String}()
        for (i, rname) in enumerate(roster_names)
            haskey(named_totals, rname) || continue
            push!(used, rname)
            row = Dict{String, Any}("Student" => rname, ASSIGNMENT_SCORES_HEADER => named_totals[rname])
            if has_id
                row["ID"] = roster_ids[i]
            end
            push!(scores_rows, row)
        end
        for name in sort(collect(keys(named_totals)); by=lowercase)
            name in used && continue
            row = Dict{String, Any}("Student" => name, ASSIGNMENT_SCORES_HEADER => named_totals[name])
            if has_id
                row["ID"] = missing
            end
            push!(scores_rows, row)
        end
    else
        for name in sort(collect(keys(named_totals)); by=lowercase)
            push!(scores_rows, Dict{String, Any}("Student" => name, ASSIGNMENT_SCORES_HEADER => named_totals[name]))
        end
    end

    sort!(scores_rows; by = r -> lowercase(string(r["Student"])))
    _write_canvas_scores_csv(
        scores_path,
        scores_rows,
        has_id,
        _assignment_max_points(master),
    )

    return (detailed_path, scores_path)
end

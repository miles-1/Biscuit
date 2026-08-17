module GenerateAssnFiles

using JSON
using Random
using ..ArchiveUtils
using ..Commands

export generate_assn_files, validate_master_json, validate_master_json_file

### Make selection.json ###

function get_new_path_name(file::String, fragment::String="")::String
    return joinpath(dirname(file), replace(basename(file), ".json" => fragment))
end

### Validate master json ###

function _validation_error(path::String, message::String)::Nothing
    throw(ArgumentError("Invalid master json at $path: $message"))
end

_object_keys(obj::Dict) = Set{String}(String(k) for k in keys(obj))
_is_number(x) = isa(x, Number) && isfinite(Float64(x))
_is_nonnegative_number(x) = _is_number(x) && x >= 0
_is_positive_number(x) = _is_number(x) && x > 0
_is_integer(x) = isa(x, Integer)
_is_nonnegative_integer(x) = _is_integer(x) && x >= 0
_is_positive_integer(x) = _is_integer(x) && x > 0

function _require_allowed_and_required_keys(obj::Dict, path::String, allowed::Set{String}, required::Set{String})
    keys_set = _object_keys(obj)
    extras = sort!(collect(setdiff(keys_set, allowed)))
    missings = sort!(collect(setdiff(required, keys_set)))
    if !isempty(extras)
        _validation_error(path, "unsupported key(s): $(join(extras, ", ")).")
    end
    if !isempty(missings)
        _validation_error(path, "missing required key(s): $(join(missings, ", ")).")
    end
    return nothing
end

function _validate_vars_object(vars_obj, path::String)::Nothing
    if !isa(vars_obj, Dict)
        _validation_error(path, "`vars` must be an object.")
    end
    for (var_name, var_spec) in vars_obj
        var_path = "$path.$var_name"
        if isa(var_spec, AbstractVector)
            if !all(v -> isa(v, Number) || isa(v, AbstractString), var_spec)
                _validation_error(var_path, "array values must be numbers or strings.")
            end
            continue
        end
        if !isa(var_spec, Dict)
            _validation_error(var_path, "must be either an array (numbers/strings) or an object with `type`, `min`, and `max`.")
        end
        allowed = Set(["type", "min", "max", "digits"])
        required = Set(["type", "min", "max"])
        _require_allowed_and_required_keys(var_spec, var_path, allowed, required)

        typ = get(var_spec, "type", nothing)
        if typ != "int" && typ != "float"
            _validation_error("$var_path.type", "must be either `int` or `float`.")
        end
        min_val = var_spec["min"]
        max_val = var_spec["max"]
        if !_is_number(min_val) || !_is_number(max_val)
            _validation_error(var_path, "`min` and `max` must be numbers.")
        end
        if min_val > max_val
            _validation_error(var_path, "`min` must be <= `max`.")
        end
        if typ == "int" && (!_is_integer(min_val) || !_is_integer(max_val))
            _validation_error(var_path, "for `type = int`, `min` and `max` must be integers.")
        end
        if typ == "int" && haskey(var_spec, "digits")
            _validation_error("$var_path.digits", "`digits` is only allowed when `type` is `float`.")
        end
        if typ == "float" && haskey(var_spec, "digits")
            digits = var_spec["digits"]
            if !_is_nonnegative_integer(digits)
                _validation_error("$var_path.digits", "must be a nonnegative integer.")
            end
        end
    end
    return nothing
end

# Validate one rubric row (old `points` form or new `max` + score-key form) and return its max contribution.
function _validate_rubric_item(item, r_path::String)::Float64
    if !isa(item, Dict)
        _validation_error(r_path, "must be an object (legacy `points` form or `max` form).")
    end
    if !haskey(item, "desc") || !isa(item["desc"], AbstractString)
        _validation_error("$r_path.desc", "must be a string.")
    end
    has_points = haskey(item, "points")
    has_max = haskey(item, "max")
    if has_points && has_max
        _validation_error(r_path, "cannot include both `points` and `max`; use one rubric form per row.")
    end
    if !has_points && !has_max
        _validation_error(r_path, "must use the `points` form or the `max` form.")
    end

    if has_points
        extras = sort!(collect(setdiff(_object_keys(item), Set(["points", "desc"]))))
        if !isempty(extras)
            _validation_error(r_path, "unsupported key(s) for `points` form: $(join(extras, ", ")).")
        end
        pts = item["points"]
        if isa(pts, Number)
            if !_is_positive_number(pts)
                _validation_error("$r_path.points", "must be a positive number or an array of positive numbers.")
            end
            return Float64(pts)
        elseif isa(pts, AbstractVector)
            if isempty(pts) || !all(_is_positive_number, pts)
                _validation_error("$r_path.points", "must be a positive number or a non-empty array of positive numbers.")
            end
            return maximum(Float64.(pts))
        else
            _validation_error("$r_path.points", "must be a positive number or an array of positive numbers.")
        end
    end

    # New form: {desc, max, "0": "...", "<max>": "...", optional intermediate scores}
    if !_is_positive_number(item["max"])
        _validation_error("$r_path.max", "must be a positive number.")
    end
    max_f = Float64(item["max"])
    score_vals = Float64[]
    for (k, v) in pairs(item)
        ks = String(k)
        if ks == "desc" || ks == "max"
            continue
        end
        num = tryparse(Float64, ks)
        if isnothing(num)
            _validation_error(r_path, "unsupported key `$ks` (expected `desc`, `max`, or a numeric score key).")
        end
        if num < 0 || num > max_f + 1e-9
            _validation_error("$r_path.$ks", "score key must be between 0 and max ($max_f), inclusive.")
        end
        if !isa(v, AbstractString)
            _validation_error("$r_path.$ks", "must be a string description.")
        end
        push!(score_vals, num)
    end
    if length(score_vals) < 2
        _validation_error(r_path, "`max` form requires at least score keys for 0 and max, each with a description.")
    end
    if !any(s -> isapprox(s, 0.0; atol=1e-9, rtol=0.0), score_vals)
        _validation_error(r_path, "`max` form must include a `0` score key with a description.")
    end
    if !any(s -> isapprox(s, max_f; atol=1e-9, rtol=0.0), score_vals)
        _validation_error(r_path, "`max` form must include a score key equal to `max` ($max_f) with a description.")
    end
    return max_f
end

function _validate_secondary_vars_object(sec_vars_obj, path::String)::Nothing
    if !isa(sec_vars_obj, Dict)
        _validation_error(path, "`secondary_vars` must be an object.")
    end
    for (k, v) in sec_vars_obj
        if !isa(v, AbstractString)
            _validation_error("$path.$k", "value must be a string with valid typst code in code mode.")
        end
    end
    return nothing
end

function _is_pick_object(obj)::Bool
    return isa(obj, Dict) && haskey(obj, "pick")
end

function _is_section_object(obj)::Bool
    return isa(obj, Dict) && haskey(obj, "section_title")
end

function _validate_question_object(q_obj, path::String)::Nothing
    if !isa(q_obj, Dict)
        _validation_error(path, "question must be an object.")
    end

    if !haskey(q_obj, "type")
        _validation_error(path, "question is missing required key `type`.")
    end
    q_type = q_obj["type"]
    if !isa(q_type, AbstractString) || !(q_type in ("essay", "fill_blank", "multiple_choice", "true_false"))
        _validation_error("$path.type", "must be one of `essay`, `fill_blank`, `multiple_choice`, or `true_false`.")
    end

    common_allowed = Set(["type", "points", "body", "vars", "secondary_vars", "correct_answer"])
    type_allowed = if q_type == "essay"
        union(common_allowed, Set(["rubric", "num_lines"]))
    elseif q_type == "fill_blank"
        union(common_allowed, Set(["rubric"]))
    else
        union(common_allowed, Set(["options"]))
    end
    _require_allowed_and_required_keys(q_obj, path, type_allowed, Set(["type", "body"]))

    if !isa(q_obj["body"], AbstractString)
        _validation_error("$path.body", "must be a string with valid typst markup.")
    end

    if haskey(q_obj, "points")
        if !_is_nonnegative_number(q_obj["points"])
            _validation_error("$path.points", "must be a nonnegative number.")
        end
    end

    if haskey(q_obj, "num_lines")
        if q_type != "essay"
            _validation_error("$path.num_lines", "is only allowed on `essay` questions.")
        end
        if !_is_nonnegative_integer(q_obj["num_lines"])
            _validation_error("$path.num_lines", "must be a nonnegative integer.")
        end
    end

    if haskey(q_obj, "vars")
        _validate_vars_object(q_obj["vars"], "$path.vars")
    end

    if haskey(q_obj, "secondary_vars")
        _validate_secondary_vars_object(q_obj["secondary_vars"], "$path.secondary_vars")
    end

    if q_type in ("essay", "fill_blank")
        if haskey(q_obj, "rubric")
            if !haskey(q_obj, "points")
                _validation_error("$path.rubric", "is only allowed when `points` is present.")
            end
            rubric = q_obj["rubric"]
            if !isa(rubric, AbstractVector)
                _validation_error("$path.rubric", "must be an array of rubric row objects.")
            end
            rubric_total = 0.0
            for (i, item) in enumerate(rubric)
                r_path = "$path.rubric[$i]"
                rubric_total += _validate_rubric_item(item, r_path)
            end
            if !isapprox(Float64(q_obj["points"]), rubric_total; atol=1e-9, rtol=0.0)
                _validation_error(path, "`points` must equal the rubric total ($rubric_total).")
            end
        end
    end

    if q_type == "essay" && haskey(q_obj, "correct_answer") && !isnothing(q_obj["correct_answer"]) && !isa(q_obj["correct_answer"], AbstractString)
        _validation_error("$path.correct_answer", "for essay questions, must be a string if provided.")
    end

    if q_type == "fill_blank"
        body = q_obj["body"]
        blank_count = length(collect(eachmatch(r"#BLANK", body)))
        if blank_count < 1
            _validation_error("$path.body", "for fill_blank questions, `#BLANK` must appear at least once.")
        end
        if haskey(q_obj, "correct_answer") && !isnothing(q_obj["correct_answer"])
            ans = q_obj["correct_answer"]
            if blank_count == 1
                if !isa(ans, AbstractString)
                    _validation_error("$path.correct_answer", "must be a string because the body has exactly one `#BLANK`.")
                end
            else
                if !isa(ans, AbstractVector) || length(ans) != blank_count || !all(a -> isa(a, AbstractString), ans)
                    _validation_error("$path.correct_answer", "must be an array of $blank_count strings because the body has $blank_count `#BLANK` markers.")
                end
            end
        end
    end

    if q_type in ("multiple_choice", "true_false")
        if !haskey(q_obj, "options")
            _validation_error("$path.options", "is required and must be a non-empty array of strings with valid typst markup.")
        end
        options = q_obj["options"]
        if !isa(options, AbstractVector) || isempty(options) || !all(o -> isa(o, AbstractString), options)
            _validation_error("$path.options", "must be a non-empty array of strings with valid typst markup.")
        end
    end

    # Missing or null `correct_answer` on MC/TF means participation credit (any answer → full points).
    if q_type == "multiple_choice" && haskey(q_obj, "correct_answer") && !isnothing(q_obj["correct_answer"])
        ans = q_obj["correct_answer"]
        n = length(q_obj["options"])
        if !_is_integer(ans) || ans < 0 || ans > n - 1
            _validation_error("$path.correct_answer", "must be an integer index between 0 and $(n - 1).")
        end
    end

    if q_type == "true_false" && haskey(q_obj, "correct_answer") && !isnothing(q_obj["correct_answer"])
        ans = q_obj["correct_answer"]
        n = length(q_obj["options"])
        if !isa(ans, AbstractVector)
            _validation_error("$path.correct_answer", "must be an array of unique valid indices (can be empty).")
        end
        if !all(_is_integer, ans)
            _validation_error("$path.correct_answer", "must contain only integer indices.")
        end
        if !all(a -> 0 <= a <= n - 1, ans)
            _validation_error("$path.correct_answer", "contains an index outside the valid range 0 to $(n - 1).")
        end
        if length(unique(ans)) != length(ans)
            _validation_error("$path.correct_answer", "must not contain duplicate indices.")
        end
    end

    return nothing
end

function _validate_pick_object(pick_obj, path::String)::Nothing
    if !isa(pick_obj, Dict)
        _validation_error(path, "pick entry must be an object.")
    end
    _require_allowed_and_required_keys(pick_obj, path, Set(["pick", "questions"]), Set(["pick", "questions"]))
    pick_n = pick_obj["pick"]
    if !_is_integer(pick_n)
        _validation_error("$path.pick", "must be an integer between 1 and (#questions - 1).")
    end
    sub_questions = pick_obj["questions"]
    if !isa(sub_questions, AbstractVector)
        _validation_error("$path.questions", "must be an array of question objects.")
    end
    n = length(sub_questions)
    if n < 2
        _validation_error("$path.questions", "must contain at least 2 questions because `pick` chooses a strict subset.")
    end
    if !(1 <= pick_n <= n - 1)
        _validation_error("$path.pick", "must be between 1 and $(n - 1).")
    end
    for (i, sub_q) in enumerate(sub_questions)
        sub_path = "$path.questions[$i]"
        if _is_pick_object(sub_q)
            _validation_error(sub_path, "pick objects cannot be nested.")
        end
        if _is_section_object(sub_q)
            _validation_error(sub_path, "sections are not allowed inside pick objects.")
        end
        _validate_question_object(sub_q, sub_path)
    end
    return nothing
end

function validate_master_json(master::Dict{String, Any})::Nothing
    allowed_top_level = Set([
        "assn_type",
        "title",
        "intro_content",
        "margin",
        "section_numbering",
        "shuffle_questions",
        "shuffle_answers",
        "version_count",
        "seed",
        "global_vars",
        "single_doc_export",
        "will_print_double_sided",
        "questions",
    ])
    _require_allowed_and_required_keys(master, "root", allowed_top_level, Set(["assn_type", "title", "questions"]))

    assn_type = master["assn_type"]
    if !isa(assn_type, AbstractString) || !(assn_type in ("quiz", "worksheet", "exam"))
        _validation_error("root.assn_type", "must be one of \"quiz\", \"worksheet\", or \"exam\".")
    end
    title = master["title"]
    if !isa(title, AbstractString) || isempty(strip(title))
        _validation_error("root.title", "must be a non-empty string.")
    end
    if haskey(master, "intro_content") && !isa(master["intro_content"], AbstractString)
        _validation_error("root.intro_content", "should be a string with valid typst markup.")
    end
    if haskey(master, "margin")
        margin = master["margin"]
        if !_is_number(margin) || !(1.5 <= margin <= 3.0)
            _validation_error("root.margin", "must be a number between 1.5 and 3.")
        end
    end
    if haskey(master, "section_numbering") && !isa(master["section_numbering"], AbstractString)
        _validation_error("root.section_numbering", "should be a string with valid typst numbering.")
    end
    if haskey(master, "shuffle_questions") && !isa(master["shuffle_questions"], Bool)
        _validation_error("root.shuffle_questions", "must be a boolean.")
    end
    if haskey(master, "shuffle_answers") && !isa(master["shuffle_answers"], Bool)
        _validation_error("root.shuffle_answers", "must be a boolean.")
    end
    if haskey(master, "version_count") && !_is_nonnegative_integer(master["version_count"])
        _validation_error("root.version_count", "must be a nonnegative integer.")
    end
    if haskey(master, "seed") && !_is_positive_integer(master["seed"])
        _validation_error("root.seed", "must be a positive integer.")
    end
    if haskey(master, "global_vars") && !isnothing(master["global_vars"]) && !isa(master["global_vars"], AbstractString)
        _validation_error("root.global_vars", "should be a string with valid typst code that gives a typst dictionary.")
    end
    if haskey(master, "single_doc_export") && !isa(master["single_doc_export"], Bool)
        _validation_error("root.single_doc_export", "must be a boolean.")
    end
    if haskey(master, "will_print_double_sided") && !isa(master["will_print_double_sided"], Bool)
        _validation_error("root.will_print_double_sided", "must be a boolean.")
    end

    questions = master["questions"]
    if !isa(questions, AbstractVector)
        _validation_error("root.questions", "must be an array.")
    end
    if isempty(questions)
        _validation_error("root.questions", "must not be empty.")
    end

    has_sections = any(_is_section_object, questions)
    has_non_sections = any(q -> !_is_section_object(q), questions)
    if has_sections && has_non_sections
        _validation_error("root.questions", "cannot mix section objects with direct question/pick entries.")
    end

    if has_sections
        for (i, section_obj) in enumerate(questions)
            sec_path = "root.questions[$i]"
            if !isa(section_obj, Dict)
                _validation_error(sec_path, "section entry must be an object.")
            end
            _require_allowed_and_required_keys(section_obj, sec_path, Set(["section_title", "questions"]), Set(["section_title", "questions"]))
            if !isa(section_obj["section_title"], AbstractString)
                _validation_error("$sec_path.section_title", "must be a string.")
            end
            sec_questions = section_obj["questions"]
            if !isa(sec_questions, AbstractVector)
                _validation_error("$sec_path.questions", "must be an array of question/pick entries.")
            end
            for (j, entry) in enumerate(sec_questions)
                entry_path = "$sec_path.questions[$j]"
                if _is_section_object(entry)
                    _validation_error(entry_path, "nested sections are not allowed.")
                elseif _is_pick_object(entry)
                    _validate_pick_object(entry, entry_path)
                else
                    _validate_question_object(entry, entry_path)
                end
            end
        end
    else
        for (i, entry) in enumerate(questions)
            entry_path = "root.questions[$i]"
            if _is_pick_object(entry)
                _validate_pick_object(entry, entry_path)
            else
                _validate_question_object(entry, entry_path)
            end
        end
    end
    return nothing
end

function validate_master_json_file(master_file::String)::Dict{String, Any}
    master = JSON.parsefile(master_file)
    if !isa(master, Dict)
        _validation_error("root", "top-level value must be a json object.")
    end
    master_dict = Dict{String, Any}(master)
    validate_master_json(master_dict)
    return master_dict
end

function process_node(node::Dict, index::Int, is_key::Bool, rng::AbstractRNG, config::NamedTuple)
    if haskey(node, "questions")
        sub_questions = node["questions"]
        n = length(sub_questions)
        indices = collect(0:(n-1)) # 0-indexed for Typst

        if is_key
            processed_subs = [process_node(sub_questions[i+1], i, true, rng, config) for i in indices]
            return Dict("indx" => index, "questions" => processed_subs)
        else
            if haskey(node, "pick")
                pick_n = node["pick"]
                shuffle!(rng, indices)
                indices = indices[1:pick_n]
                if !config.shuffle_q sort!(indices) end
            else
                if config.shuffle_q shuffle!(rng, indices) end
            end
            
            processed_subs = [process_node(sub_questions[i+1], i, false, rng, config) for i in indices]
            return Dict("indx" => index, "questions" => processed_subs)
        end
    
    else
        if is_key
            return index
        else
            res = Dict{String, Any}()
            needs_dict = false

            if config.shuffle_a && get(node, "type", "") in ["multiple_choice", "true_false"]
                opts_len = haskey(node, "options") ? length(node["options"]) : length(get(node, "func_options", []))
                if opts_len > 0
                    permutation = shuffle(rng, collect(Int, 0:(opts_len-1)))
                    if any(permutation .!= 0:(opts_len-1))
                        res["option_permutation"] = permutation
                        needs_dict = true
                    end
                end
            end

            if haskey(node, "vars")
                vars_dict = Dict{String, Any}()
                for (k, v) in node["vars"]
                    if isa(v, AbstractVector)
                        vars_dict[k] = rand(rng, v)
                    elseif isa(v, Dict)
                        min_val = v["min"]
                        max_val = v["max"]
                        if v["type"] == "int"
                            vars_dict[k] = rand(rng, Int(min_val):Int(max_val))
                        elseif v["type"] == "float"
                            digits = get(v, "digits", 2)
                            val = rand(rng) * (Float64(max_val) - Float64(min_val)) + Float64(min_val)
                            vars_dict[k] = round(val; digits)
                        end
                    end
                end
                res["vars"] = vars_dict
                needs_dict = true
            end

            if needs_dict
                res["indx"] = index
                return res
            else
                return index
            end
        end
    end
end

function generate_selection_json(; master_file::String, output_dir::String)::String
    master = JSON.parsefile(master_file)
    output_file = joinpath(output_dir, "selection.json")
    seed = get(master, "seed", 1234)
    rng = Xoshiro(seed) 
    shuffle_q = get(master, "shuffle_questions", false)
    shuffle_a = get(master, "shuffle_answers", false)
    version_count = get(master, "version_count", 1)
    config = (; shuffle_q, shuffle_a)
    versions = []
    key_version = Dict("is_key" => true, "questions" => [])
    for (i, sec) in enumerate(master["questions"])
        push!(key_version["questions"], process_node(sec, i - 1, true, rng, config))
    end
    push!(versions, key_version)
    for assn_id in 0:(version_count - 1)
        student_version = Dict("assn_id" => assn_id, "questions" => [])
        for (i, sec) in enumerate(master["questions"])
            push!(student_version["questions"], process_node(sec, i - 1, false, rng, config))
        end
        push!(versions, student_version)
    end
    selection = Dict("versions" => versions)
    open(output_file, "w") do f; JSON.print(f, selection) end
    println("Created: selection.json - $version_count student version(s) and 1 key")
    return output_file
end

### Generate PDFs ###

function generate_pdf(;
    master_file::String,
    selection_file::String,
    single_doc_export::Bool,
    will_print_double_sided::Bool,
)::String
    if single_doc_export
        output_path = get_new_path_name(master_file, "_all_versions.pdf")
    else
        output_path = get_new_path_name(master_file, "_versions")
        if isdir(output_path)
            rm(output_path, recursive=true)
            println("The folder $output_path already existed, so it was deleted.")
        end
        mkdir(output_path)
    end
    typst_compile_assn(;
        master_file,
        selection_file,
        output_path,
        single_doc_export,
        will_print_double_sided,
    )
    println("Created: $(basename(output_path))")
    return output_path
end

### Generate json files from Typst

function generate_page_elements_json(; master_file::String, selection_file::String, output_dir::String)::Nothing
    query_output = typst_query_assn(; master_file, selection_file, label="page_elems")
    query_output = replace(query_output, r"\"([\d\.]+)pt\"" => s"\1")
    parsed_data = JSON.parse(query_output)
    output_file = joinpath(output_dir, "page_elements.json")
    open(output_file, "w") do f; JSON.print(f, parsed_data) end
    println("Created: page_elements.json")
    return nothing
end

function generate_var_answers_json(; master_file::String, selection_file::String, output_dir::String)::Nothing
    query_output = typst_query_assn(; master_file, selection_file, label="var_answers")
    output_file = joinpath(output_dir, "var_answers.json")
    write(output_file, query_output)
    println("Created: var_answers.json")
    return nothing
end

### Main ###

function generate_assn_files(
    master_file_raw::String;
    class_csv_file::Union{Nothing, AbstractString}=nothing,
    output_name::Union{Nothing, AbstractString}=nothing,
)::Nothing
    @assert endswith(lowercase(master_file_raw), ".json") "`master_file` must be json file"
    master = validate_master_json_file(master_file_raw)
    single_doc_export = Bool(get(master, "single_doc_export", false))
    will_print_double_sided = Bool(get(master, "will_print_double_sided", true))
    
    # Convert to relative paths early since Typst reads from stdin and resolves relative to CWD
    master_file = replace(relpath(master_file_raw), "\\" => "/")
    base_dir = dirname(abspath(master_file_raw))
    stem = if output_name !== nothing && !isempty(strip(String(output_name)))
        strip(String(output_name))
    else
        first(splitext(basename(master_file_raw)))
    end
    assn_versions_file = joinpath(base_dir, stem * ".assnversions")
    
    mktempdir(base_dir) do temp_dir_raw
        temp_dir = replace(relpath(temp_dir_raw), "\\" => "/")
        println("Created: $temp_dir")
        println("Added: master.json")
        if class_csv_file !== nothing && !isempty(strip(String(class_csv_file)))
            println("Added: $(basename(String(class_csv_file)))")
        end
        selection_file = generate_selection_json(; master_file, output_dir=temp_dir)
        generate_pdf(; master_file, selection_file, single_doc_export, will_print_double_sided)
        generate_page_elements_json(; master_file, selection_file, output_dir=temp_dir)
        generate_var_answers_json(; master_file, selection_file, output_dir=temp_dir)
        create_archive(;
            archive_path=assn_versions_file,
            master_file,
            json_dir=temp_dir,
            class_csv_file=class_csv_file,
        )
    end
    println("Created: $assn_versions_file")
    return nothing
end

end # module

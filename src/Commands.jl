module Commands

using ..Paths: package_root

export typst_compile_assn
export typst_query_assn
export typst_compile_feedback_bundle
export typst_compile_question_preview
export typst_compile_answer_svgs
export typst_check_markup

assn_typst_file() = joinpath(package_root(), "typst_doc_generators", "assignment.typ")
feedback_typst_file() = joinpath(package_root(), "typst_doc_generators", "feedback.typ")
question_preview_typst_file() = joinpath(package_root(), "typst_doc_generators", "question_preview.typ")
answers_typst_file() = joinpath(package_root(), "typst_doc_generators", "answers.typ")

# Path relative to the Typst working directory (the master JSON's folder).
function _rel_to(dir::String, path::String)::String
    return replace(relpath(abspath(path), abspath(dir)), "\\" => "/")
end

function _typst_cmd(args::Vector{String}; dir::Union{Nothing,String}=nothing)
    return isnothing(dir) ? Cmd(`typst $args`) : Cmd(`typst $args`; dir=abspath(dir))
end

function _run_typst_stdin(source_file::String, args::Vector{String}; dir::Union{Nothing,String}=nothing)
    stderr_buf = IOBuffer()
    try
        run(pipeline(_typst_cmd(args; dir); stdin=source_file, stderr=stderr_buf))
        return nothing
    catch e
        err = strip(String(take!(stderr_buf)))
        isempty(err) && rethrow(e)
        error(err)
    end
end

function _read_typst_stdin(source_file::String, args::Vector{String}; dir::Union{Nothing,String}=nothing)::String
    stderr_buf = IOBuffer()
    try
        return read(pipeline(_typst_cmd(args; dir); stdin=source_file, stderr=stderr_buf), String)
    catch e
        err = strip(String(take!(stderr_buf)))
        isempty(err) && rethrow(e)
        error(err)
    end
end

function typst_compile_assn(;
    master_file::String,
    selection_file::String,
    output_path::String,
    source_file::String=assn_typst_file(),
    single_doc_export::Bool=false,
    will_print_double_sided::Bool=true,
)::Nothing
    # Always compile from the master JSON's folder so `image("foo.svg")` resolves
    # there, not wherever the Biscuit process happened to start.
    work_abs = dirname(abspath(master_file))
    args = String["compile"]
    if !single_doc_export
        append!(args, ["--features", "bundle", "--format", "bundle"])
    end
    append!(args, [
        "--root", ".",
        "--input", "master=$(_rel_to(work_abs, master_file))",
        "--input", "selection=$(_rel_to(work_abs, selection_file))",
        "--input", "single_doc_export=$single_doc_export",
        "--input", "will_print_double_sided=$will_print_double_sided",
        "-",
        _rel_to(work_abs, output_path),
    ])
    return _run_typst_stdin(source_file, args; dir=work_abs)
end

function typst_query_assn(;
    master_file::String,
    selection_file::String,
    label::String,
    source_file::String=assn_typst_file(),
)::String
    # typst query is deprecated; equivalent eval expression extracts the metadata value.
    work_abs = dirname(abspath(master_file))
    args = [
        "eval",
        "--in", "-",
        "--root", ".",
        "--input", "master=$(_rel_to(work_abs, master_file))",
        "--input", "selection=$(_rel_to(work_abs, selection_file))",
        "--input", "single_doc_export=true",
        "query(<$label>).first().value",
    ]
    return _read_typst_stdin(source_file, args; dir=work_abs)
end

function typst_compile_feedback_bundle(;
    grading_data_file::String,
    annotated_scan_folder::String,
    assn_page_counts_file::String,
    output_dir::String,
    source_file::String=feedback_typst_file(),
)::Nothing
    args = [
        "compile",
        "--features", "bundle",
        "--format", "bundle",
        "--input", "grading_data=$grading_data_file",
        "--input", "annotated_scan_folder=$annotated_scan_folder",
        "--input", "assn_page_counts=$assn_page_counts_file",
        "-",
        output_dir,
    ]
    return _run_typst_stdin(source_file, args)
end

function _without_assignment_import(src::String)::String
    return replace(src, r"^#import \"assignment\.typ\"[^\n]*\r?\n" => ""; count=1)
end

function _stdin_source_with_assignment(typst_file::String)::String
    # Concatenate so the file compiles from stdin. If we instead compile a copy of it
    # inside the temp dir, `eval()` resolves `image("foo.svg")` relative to that
    # copy — not the assignment folder.
    assn = read(assn_typst_file(), String)
    rest = _without_assignment_import(read(typst_file, String))
    return assn * "\n" * rest
end

function typst_compile_question_preview(;
    preview_json::String,
    output_svg::String,
    work_dir::String,
    stdout_io::IO=devnull,
    stderr_io::IO=stderr,
)::Nothing
    work_abs = abspath(work_dir)
    args = [
        "compile",
        "--root", ".",
        "--input", "preview=$(_rel_to(work_abs, preview_json))",
        "--format", "svg",
        "-",
        _rel_to(work_abs, output_svg),
    ]
    cmd = pipeline(
        Cmd(`typst $args`; dir=work_abs);
        stdin=IOBuffer(_stdin_source_with_assignment(question_preview_typst_file())),
        stdout=stdout_io,
        stderr=stderr_io,
    )
    run(cmd)
    return nothing
end

# One SVG page per (version, question) listed in `jobs_file`, written to `output_pattern` ("…-{p}.svg").
function typst_compile_answer_svgs(;
    work_dir::String,
    master_file::String,
    selection_file::String,
    jobs_file::String,
    output_pattern::String,
)::Nothing
    work_abs = abspath(work_dir)
    args = [
        "compile",
        "--root", ".",
        "--input", "answer_master=$(_rel_to(work_abs, master_file))",
        "--input", "answer_selection=$(_rel_to(work_abs, selection_file))",
        "--input", "answer_jobs=$(_rel_to(work_abs, jobs_file))",
        "--format", "svg",
        "-",
        _rel_to(work_abs, output_pattern),
    ]
    stderr_buf = IOBuffer()
    try
        run(pipeline(
            Cmd(`typst $args`; dir=work_abs);
            stdin=IOBuffer(_stdin_source_with_assignment(answers_typst_file())),
            stderr=stderr_buf,
        ))
    catch e
        err = strip(String(take!(stderr_buf)))
        isempty(err) && rethrow(e)
        error(err)
    end
    return nothing
end

const _CHECK_ERROR_RE = r"(?m)^(?:.*[\\/])?t(\d+)\.typ:(\d+):(\d+): error: ([^\r\n]*)"

# Evaluate each text as Typst markup, like `eval(text, mode: "markup")` in feedback.typ. Returns,
# per text, `nothing` or a Dict with "message", "line", "column" (1-based, inside that text).
# Each text is its own included file so the error names it; Typst stops at the first error, so the
# failing text is dropped and the rest re-run.
function typst_check_markup(texts::AbstractVector{<:AbstractString})
    results = Vector{Union{Nothing,Dict{String,Any}}}(nothing, length(texts))
    isempty(texts) && return results
    mktempdir() do dir
        for (i, text) in enumerate(texts)
            write(joinpath(dir, "t$i.typ"), text)
        end
        pending = collect(eachindex(texts))
        while !isempty(pending)
            write(joinpath(dir, "main.typ"), join(("#include \"t$i.typ\"\n" for i in pending)))
            stderr_buf = IOBuffer()
            cmd = Cmd(`typst eval --diagnostic-format short --root . --in main.typ none`; dir=abspath(dir))
            success(pipeline(cmd; stdout=devnull, stderr=stderr_buf)) && break
            err = String(take!(stderr_buf))
            m = match(_CHECK_ERROR_RE, err)
            if isnothing(m) || parse(Int, m[1]) ∉ pending
                msg = strip(err)
                for i in pending
                    results[i] = Dict{String,Any}("message" => isempty(msg) ? "Typst check failed" : msg)
                end
                break
            end
            i = parse(Int, m[1])
            results[i] = Dict{String,Any}(
                "message" => strip(m[4]),
                "line" => parse(Int, m[2]),
                "column" => parse(Int, m[3]) + 1,  # Typst columns are 0-based
            )
            filter!(!=(i), pending)
        end
    end
    return results
end

end # module

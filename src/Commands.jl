module Commands

using ..Paths: package_root

export typst_compile_assn
export typst_query_assn
export typst_compile_feedback_bundle
export typst_compile_question_preview

assn_typst_file() = joinpath(package_root(), "typst_doc_generators", "assignment.typ")
feedback_typst_file() = joinpath(package_root(), "typst_doc_generators", "feedback.typ")
question_preview_typst_file() = joinpath(package_root(), "typst_doc_generators", "question_preview.typ")

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

function _question_preview_stdin_source()::String
    # Concatenate so preview compiles from stdin. If we instead compile a copy of
    # question_preview.typ inside the temp dir, `eval()` resolves `image("foo.svg")`
    # relative to that copy — not the assignment folder.
    assn = read(assn_typst_file(), String)
    preview = _without_assignment_import(read(question_preview_typst_file(), String))
    return assn * "\n" * preview
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
        stdin=IOBuffer(_question_preview_stdin_source()),
        stdout=stdout_io,
        stderr=stderr_io,
    )
    run(cmd)
    return nothing
end

end # module

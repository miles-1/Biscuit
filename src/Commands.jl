module Commands

using ..Paths: package_root

export typst_compile_assn
export typst_query_assn
export typst_compile_feedback_bundle

assn_typst_file() = joinpath(package_root(), "typst_doc_generators", "assignment.typ")
feedback_typst_file() = joinpath(package_root(), "typst_doc_generators", "feedback.typ")

function _run_typst_stdin(source_file::String, args::Vector{String})
    run(pipeline(source_file, `typst $args`))
    return nothing
end

function _read_typst_stdin(source_file::String, args::Vector{String})::String
    return read(pipeline(source_file, `typst $args`), String)
end

function typst_compile_assn(;
    master_file::String,
    selection_file::String,
    output_path::String,
    source_file::String=assn_typst_file(),
    single_doc_export::Bool=false,
    will_print_double_sided::Bool=true,
)::Nothing
    args = String["compile"]
    if !single_doc_export
        append!(args, ["--features", "bundle", "--format", "bundle"])
    end
    append!(args, [
        "--input", "master=$master_file",
        "--input", "selection=$selection_file",
        "--input", "single_doc_export=$single_doc_export",
        "--input", "will_print_double_sided=$will_print_double_sided",
        "-",
        output_path,
    ])
    return _run_typst_stdin(source_file, args)
end

function typst_query_assn(;
    master_file::String,
    selection_file::String,
    label::String,
    source_file::String=assn_typst_file(),
)::String
    # typst query is deprecated; equivalent eval expression extracts the metadata value.
    args = [
        "eval",
        "--in", "-",
        "--input", "master=$master_file",
        "--input", "selection=$selection_file",
        "--input", "single_doc_export=true",
        "query(<$label>).first().value",
    ]
    return _read_typst_stdin(source_file, args)
end

function typst_compile_feedback_bundle(;
    grading_data_file::String,
    annotated_scan_folder::String,
    output_dir::String,
    source_file::String=feedback_typst_file(),
)::Nothing
    args = [
        "compile",
        "--features", "bundle",
        "--format", "bundle",
        "--input", "grading_data=$grading_data_file",
        "--input", "annotated_scan_folder=$annotated_scan_folder",
        "-",
        output_dir,
    ]
    return _run_typst_stdin(source_file, args)
end

end # module

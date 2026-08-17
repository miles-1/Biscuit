module ArchiveUtils

using JSON
using ZipFile

export get_archive_path
export make_archive_from_dir
export create_archive
export with_archive_dir
export extract_archive
export ExistingTempArchiveError

const JSON_FILES = (
    "master.json",
    "selection.json",
    "page_elements.json",
    "var_answers.json",
    "processed_assn_data.json",
)

struct ExistingTempArchiveError <: Exception
    archive_path::String
    temp_dir_path::String
end

function Base.showerror(io::IO, e::ExistingTempArchiveError)
    print(io, "Temporary extracted archive already exists at $(e.temp_dir_path) for $(e.archive_path)")
end

function get_archive_path(input_file::String; is_assn_versions::Bool=false, parent_dir::String)::String
    return joinpath(parent_dir, first(splitext(basename(input_file))) * ".assn" * (is_assn_versions ? "versions" : ""))
end

function make_archive_from_dir(source_dir::String, archive_path::String; rebuild::Bool=true)::String
    if rebuild
        @assert isfile(archive_path) "Missing archive file: $archive_path"
    end
    rm(archive_path; force=true) # Rebuild archive from scratch to avoid stale entries.
    writer = ZipFile.Writer(archive_path)
    try
        source_root = abspath(source_dir)
        for (dir_path, _, file_names) in walkdir(source_root)
            for file_name in sort(file_names)
                file_path = joinpath(dir_path, file_name)
                rel_path = relpath(file_path, source_root)
                zip_path = replace(rel_path, '\\' => '/')
                zip_entry = ZipFile.addfile(writer, zip_path; method=ZipFile.Deflate)
                open(file_path, "r") do f
                    write(zip_entry, read(f))
                end
            end
        end
    finally
        close(writer)
    end
    return archive_path
end

function create_archive(;
    archive_path::String,
    master_file::String,
    json_dir::String,
    class_csv_file::Union{Nothing, AbstractString}=nothing,
)::String
    @assert isfile(master_file) "Missing master file: $master_file"
    mktempdir() do temp_dir
        for file_name in JSON_FILES
            if file_name == "master.json"
                cp(master_file, joinpath(temp_dir, "master.json"); force=true)
                continue
            end
            source_file = joinpath(json_dir, file_name)
            if isfile(source_file)
                cp(source_file, joinpath(temp_dir, file_name); force=true)
            end
        end
        if !isnothing(class_csv_file)
            isfile(class_csv_file) || throw(ArgumentError("Class CSV not found: $class_csv_file"))
            cp(class_csv_file, joinpath(temp_dir, basename(class_csv_file)); force=true)
        end
        make_archive_from_dir(temp_dir, archive_path; rebuild=false)
    end
    return archive_path
end

function _safe_archive_target(temp_dir::AbstractString, entry_name::AbstractString)::String
    # Reject absolute entry names and parent-directory segments.
    @assert !isabspath(entry_name) && !occursin(r"(^|/|\\)\.\.(/|\\|$)", entry_name) "Unsafe archive entry path: $entry_name"
    root = abspath(temp_dir)
    target = abspath(joinpath(root, entry_name))
    root_prefix = root * Base.Filesystem.path_separator
    @assert startswith(target, root_prefix) || target == root "Unsafe archive entry path: $entry_name"
    return target
end

function with_archive_dir(f::Function, archive_path::String; selected_path::String="")
    @assert isfile(archive_path) "Archive path does not exist: $archive_path"
    mktempdir() do temp_dir
        reader = ZipFile.Reader(archive_path)
        try
            for zip_entry in reader.files
                if endswith(zip_entry.name, '/') || (!isempty(selected_path) && zip_entry.name != selected_path)
                    continue
                end
                target_path = _safe_archive_target(temp_dir, zip_entry.name)
                mkpath(dirname(target_path))
                open(target_path, "w") do f
                    write(f, read(zip_entry))
                end
            end
        finally
            close(reader)
        end
        return f(temp_dir)
    end
end

function extract_archive(archive_path::String; use_existing_tmp::Bool=false)::String
    @assert isfile(archive_path) "Archive path does not exist: $archive_path"
    temp_dir_path = abspath(archive_path) * ".tmp"
    if isdir(temp_dir_path)
        if use_existing_tmp
            return temp_dir_path
        end
        throw(ExistingTempArchiveError(abspath(archive_path), temp_dir_path))
    end
    # Also treat a relative sibling tmp as existing (UI may pass "./file.assn").
    rel_tmp = archive_path * ".tmp"
    if rel_tmp != temp_dir_path && isdir(rel_tmp)
        if use_existing_tmp
            return abspath(rel_tmp)
        end
        throw(ExistingTempArchiveError(abspath(archive_path), abspath(rel_tmp)))
    end
    temp_dir = mkdir(temp_dir_path)
    reader = ZipFile.Reader(archive_path)
    try
        for zip_entry in reader.files
            if endswith(zip_entry.name, '/')
                mkpath(_safe_archive_target(temp_dir, zip_entry.name))
                continue
            end
            target_path = _safe_archive_target(temp_dir, zip_entry.name)
            mkpath(dirname(target_path))
            open(target_path, "w") do f
                write(f, read(zip_entry))
            end
        end
    finally
        close(reader)
    end
    return temp_dir
end

end # end TestArchiveUtils

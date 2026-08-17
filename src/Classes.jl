module Classes

using CSV
using Dates
using ..Paths: config_dir

export classes_dir
export class_csv_path
export list_classes
export add_class
export add_class_from_csv_text
export delete_class
export reveal_path_in_file_manager
export sanitize_class_name
export write_sanitized_roster_csv

const ALLOWED_ROSTER_COLUMNS = ("students", "student_id", "student_email")

function classes_dir()::String
    return joinpath(config_dir(), "classes")
end

function sanitize_class_name(name::AbstractString)::String
    s = strip(String(name))
    isempty(s) && throw(ArgumentError("Class name must be non-empty."))
    occursin(r"[\\/]", s) && throw(ArgumentError("Class name cannot contain path separators."))
    occursin(r"^\.+$", s) && throw(ArgumentError("Invalid class name."))
    return s
end

function class_csv_path(class_name::AbstractString)::String
    return joinpath(classes_dir(), sanitize_class_name(class_name) * ".csv")
end

function ensure_classes_dir()
    mkpath(classes_dir())
    return nothing
end

"""
Read a user-provided roster CSV, require `students`, keep only students/student_id/student_email,
and write it to `dest_path`.
"""
function write_sanitized_roster_csv(source_path::AbstractString, dest_path::AbstractString)
    isfile(source_path) || throw(ArgumentError("CSV file not found: $source_path"))
    table = CSV.File(source_path)
    namemap = Dict(lowercase(String(n)) => n for n in propertynames(table))
    haskey(namemap, "students") || throw(ArgumentError(
        "Roster CSV must include a `students` column."
    ))
    out_header = Symbol[]
    for col in ALLOWED_ROSTER_COLUMNS
        if haskey(namemap, col)
            push!(out_header, Symbol(col))
        end
    end
    rows = NamedTuple[]
    hdr = Tuple(out_header)
    for row in table
        vals = ntuple(i -> row[namemap[String(out_header[i])]], length(out_header))
        push!(rows, NamedTuple{hdr}(vals))
    end
    mkpath(dirname(dest_path))
    CSV.write(dest_path, rows)
    return dest_path
end

function _class_info_from_path(path::String)::Dict{String, Any}
    class_name = first(splitext(basename(path)))
    table = try
        CSV.File(path; header=1)
    catch
        return Dict(
            "class_name" => class_name,
            "path" => path,
            "num_students" => 0,
            "has_student_id" => false,
            "has_student_email" => false,
            "last_edited" => string(Dates.unix2datetime(mtime(path))),
            "error" => "Could not read CSV",
        )
    end
    names_lower = Set(lowercase.(String.(propertynames(table))))
    return Dict(
        "class_name" => class_name,
        "path" => abspath(path),
        "num_students" => length(table),
        "has_student_id" => "student_id" in names_lower,
        "has_student_email" => "student_email" in names_lower,
        "last_edited" => string(Dates.unix2datetime(mtime(path))),
    )
end

function list_classes()::Vector{Dict{String, Any}}
    ensure_classes_dir()
    dir = classes_dir()
    files = sort(filter(f -> endswith(lowercase(f), ".csv"), readdir(dir)))
    return [_class_info_from_path(joinpath(dir, f)) for f in files]
end

function add_class(class_name::AbstractString, source_csv::AbstractString)::Dict{String, Any}
    ensure_classes_dir()
    name = sanitize_class_name(class_name)
    dest = class_csv_path(name)
    isfile(dest) && throw(ArgumentError("A class named $(repr(name)) already exists."))
    write_sanitized_roster_csv(source_csv, dest)
    return _class_info_from_path(dest)
end

"""
Add a class from in-memory CSV text (used when the browser native file picker supplies
file contents rather than a filesystem path).
"""
function add_class_from_csv_text(class_name::AbstractString, csv_text::AbstractString)::Dict{String, Any}
    mktempdir() do d
        src = joinpath(d, "upload.csv")
        write(src, String(csv_text))
        return add_class(class_name, src)
    end
end

function delete_class(class_name::AbstractString)
    path = class_csv_path(class_name)
    isfile(path) || throw(ArgumentError("Class $(repr(class_name)) not found."))
    rm(path)
    return nothing
end

function reveal_path_in_file_manager(path::AbstractString)
    isfile(path) || isdir(path) || throw(ArgumentError("Path not found: $path"))
    if Sys.isapple()
        run(`open -R $path`)
    elseif Sys.iswindows()
        run(`explorer /select,$(replace(abspath(path), '/' => '\\'))`)
    else
        run(`xdg-open $(dirname(abspath(path)))`)
    end
    return nothing
end

end # module

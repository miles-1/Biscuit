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
export read_roster_table
export roster_has_id
export roster_has_email

const ROSTER_COLUMNS = ("Student", "ID", "Email")

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

function _is_points_possible_cell(value)::Bool
    (ismissing(value) || value === nothing) && return false
    return lowercase(strip(string(value))) == "points possible"
end

function _roster_cell(value)
    (ismissing(value) || value === nothing) && return missing
    s = strip(string(value))
    return isempty(s) ? missing : String(s)
end

function _is_test_student_name(name::AbstractString)::Bool
    return lowercase(strip(String(name))) == "student, test"
end

function _resolve_roster_header(namemap::Dict, canonical::AbstractString)::Union{Nothing, Symbol}
    return get(namemap, lowercase(canonical), nothing)
end

"""
Read a roster CSV into a NamedTuple of columns using Canvas headers (`Student`, optional `ID`
and `Email`). Drops a Canvas "Points Possible" row if present, and drops a trailing
`Student, Test` row if present.
"""
function read_roster_table(source_path::AbstractString)::NamedTuple
    isfile(source_path) || throw(ArgumentError("CSV file not found: $source_path"))
    table = CSV.File(source_path)
    namemap = Dict(lowercase(String(n)) => n for n in propertynames(table))
    resolved = Dict{String, Symbol}()
    for col in ROSTER_COLUMNS
        src = _resolve_roster_header(namemap, col)
        src === nothing || (resolved[col] = src)
    end
    haskey(resolved, "Student") || throw(ArgumentError(
        "Roster CSV must include a `Student` column."
    ))

    student_vals = String[]
    id_vals = haskey(resolved, "ID") ? Vector{Any}() : nothing
    email_vals = haskey(resolved, "Email") ? Vector{Any}() : nothing
    student_src = resolved["Student"]
    id_src = get(resolved, "ID", nothing)
    email_src = get(resolved, "Email", nothing)

    for row in table
        raw_name = row[student_src]
        _is_points_possible_cell(raw_name) && continue
        name = _roster_cell(raw_name)
        name === missing && continue
        push!(student_vals, String(name))
        if id_vals !== nothing
            push!(id_vals, _roster_cell(row[id_src]))
        end
        if email_vals !== nothing
            push!(email_vals, _roster_cell(row[email_src]))
        end
    end

    if !isempty(student_vals) && _is_test_student_name(student_vals[end])
        pop!(student_vals)
        id_vals !== nothing && pop!(id_vals)
        email_vals !== nothing && pop!(email_vals)
    end

    cols = Pair{Symbol, Any}[:Student => student_vals]
    id_vals !== nothing && push!(cols, :ID => id_vals)
    email_vals !== nothing && push!(cols, :Email => email_vals)
    return NamedTuple(cols)
end

roster_has_id(table)::Bool = table !== nothing && haskey(table, :ID)
roster_has_email(table)::Bool = table !== nothing && haskey(table, :Email)

"""
Read a user-provided roster CSV, require `Student`, keep only Student/ID/Email, drop a
Canvas "Points Possible" row and a trailing `Student, Test` row if present, and write it
to `dest_path`.
"""
function write_sanitized_roster_csv(source_path::AbstractString, dest_path::AbstractString)
    table = read_roster_table(source_path)
    mkpath(dirname(dest_path))
    n = length(table.Student)
    headers = String["Student"]
    roster_has_id(table) && push!(headers, "ID")
    roster_has_email(table) && push!(headers, "Email")
    col_syms = Tuple(Symbol.(headers))
    rows = [
        NamedTuple{col_syms}(Tuple(
            h == "Student" ? table.Student[i] :
            h == "ID" ? table.ID[i] :
            table.Email[i]
            for h in headers
        ))
        for i in 1:n
    ]
    if isempty(rows)
        open(dest_path, "w") do io
            println(io, join(headers, ","))
        end
    else
        CSV.write(dest_path, rows)
    end
    return dest_path
end

function _class_info_from_path(path::String)::Dict{String, Any}
    class_name = first(splitext(basename(path)))
    table = try
        read_roster_table(path)
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
    return Dict(
        "class_name" => class_name,
        "path" => abspath(path),
        "num_students" => length(table.Student),
        "has_student_id" => roster_has_id(table),
        "has_student_email" => roster_has_email(table),
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

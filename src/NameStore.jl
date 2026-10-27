module NameStore

"""
    NameStore

App-managed home for a class's name-recognition data, so the user never has to
keep track of handwriting folders or `.namereader` files themselves.

Everything lives beside the class roster, under `classes/`:

```text
classes/
  EvolutionFa26.csv
  EvolutionFa26_name_data/
    images/
      lastname,firstname/
        table_<id>.png        crop from a handwritten name table
        assn_<id>.png         crop from a scanned assignment's name line
    EvolutionFa26.namereader
    EvolutionFa26.namereader.json
    EvolutionFa26_example_overlays/
```

`<id>` is a hash of the image's pixels, which is what makes merging repeated
scans safe: the same crop always lands on the same file name, so re-adding it is
a no-op and no student folder is ever overwritten.
"""

using Colors: Gray
using Dates
using FileIO: load
using SHA: sha256

using ..Classes: classes_dir, class_csv_path, sanitize_class_name, read_roster_table
using ..NameReader: NAME_IMAGE_KINDS, name_image_id, name_image_kind, name_image_prefix,
    read_training_sidecar

export NameImageCandidate
export class_name_data_dir
export class_name_images_dir
export class_namereader_path
export class_namereader_sidecar_path
export class_name_data_summary
export class_namereader_for_guessing
export image_content_id
export merge_name_images!
export sanitize_student_folder_name
export scan_class_name_images
export class_name_images_listing
export class_name_image_file
export delete_class_name_image!
export reassign_class_name_image!

const NAME_DATA_SUFFIX = "_name_data"
const IMAGES_SUBDIR = "images"
# Only the leading hex of the digest is used: 48 bits is far more than enough to
# tell one crop from another within a single class.
const CONTENT_ID_LENGTH = 12

"""One image waiting to be filed under `student` in a class's store."""
struct NameImageCandidate
    student::String
    kind::Symbol
    path::String
end

class_name_data_dir(class_name::AbstractString)::String =
    joinpath(classes_dir(), sanitize_class_name(class_name) * NAME_DATA_SUFFIX)

"""
The folder handed to training: one subfolder per student, and nothing else, so
every subfolder is a label.
"""
class_name_images_dir(class_name::AbstractString)::String =
    joinpath(class_name_data_dir(class_name), IMAGES_SUBDIR)

class_namereader_path(class_name::AbstractString)::String =
    joinpath(class_name_data_dir(class_name), sanitize_class_name(class_name) * ".namereader")

class_namereader_sidecar_path(class_name::AbstractString)::String =
    class_namereader_path(class_name) * ".json"

"""
    sanitize_student_folder_name(name)

`"Smith, John"` → `"smith_john"`, matching `feedback.typ` and
`GoogleDrive.sanitize_student_name` so the same student always maps to the same
folder. `NameReader.intersect_roster` maps the result back onto roster names.
"""
function sanitize_student_folder_name(name::AbstractString)::String
    folder = lowercase(replace(strip(String(name)), ", " => "_"))
    folder = replace(folder, r"[\\/]" => "-")
    isempty(folder) && throw(ArgumentError("Student name must be non-empty."))
    return folder
end

"""
    image_content_id(path)

A short hash of the image's grayscale pixels. Decoding first rather than hashing
the file means two crops that render identically are recognised as identical
even if they were encoded by different writers.
"""
function image_content_id(path::AbstractString)::String
    return image_content_id_from_image(load(String(path)))
end

function image_content_id_from_image(image)::String
    height, width = size(image)[1], size(image)[2]
    payload = Vector{UInt8}(undef, height * width + 8)
    for (offset, value) in enumerate(reinterpret(UInt8, UInt32[height, width]))
        payload[offset] = value
    end
    index = 8
    for row in 1:height, column in 1:width
        index += 1
        payload[index] = round(UInt8, clamp(Float64(Gray(image[row, column])), 0.0, 1.0) * 255)
    end
    return bytes2hex(sha256(payload))[1:CONTENT_ID_LENGTH]
end

"""
    merge_name_images!(class_name, candidates)

File each candidate under `images/<student>/<prefix><id>.png`, skipping any whose
pixels already sit in that student's folder. Existing students and images are
left alone, so processing a second batch of scans adds to the class rather than
replacing it.

Returns `(; added, skipped, students, images_dir)`.
"""
function merge_name_images!(class_name::AbstractString, candidates)
    images_root = class_name_images_dir(class_name)
    added = 0
    skipped = 0
    touched = Set{String}()

    for candidate in candidates
        isfile(candidate.path) || continue
        student_dir = joinpath(images_root, sanitize_student_folder_name(candidate.student))
        destination = joinpath(
            student_dir,
            string(name_image_prefix(candidate.kind), image_content_id(candidate.path), ".png"),
        )
        if isfile(destination)
            skipped += 1
            continue
        end
        mkpath(student_dir)
        cp(candidate.path, destination)
        added += 1
        push!(touched, basename(student_dir))
    end

    return (; added, skipped, students=length(touched), images_dir=images_root)
end

"""
    scan_class_name_images(class_name)

`student => (kind => sorted content ids)` for everything currently stored.
"""
function scan_class_name_images(class_name::AbstractString)::Dict{String,Dict{Symbol,Vector{String}}}
    images_root = class_name_images_dir(class_name)
    stored = Dict{String,Dict{Symbol,Vector{String}}}()
    isdir(images_root) || return stored

    for entry in sort(readdir(images_root))
        student_dir = joinpath(images_root, entry)
        (isdir(student_dir) && !startswith(entry, ".")) || continue
        by_kind = Dict{Symbol,Vector{String}}(kind => String[] for kind in NAME_IMAGE_KINDS)
        for file in sort(readdir(student_dir))
            endswith(lowercase(file), ".png") || continue
            push!(by_kind[name_image_kind(file)], name_image_id(file))
        end
        any(!isempty, values(by_kind)) && (stored[entry] = by_kind)
    end
    return stored
end

# Ids the sidecar says were part of the last training run, as `student => kind => ids`.
function _trained_ids(sidecar)::Dict{String,Dict{Symbol,Set{String}}}
    trained = Dict{String,Dict{Symbol,Set{String}}}()
    isa(sidecar, AbstractDict) || return trained
    students = get(sidecar, "students", nothing)
    isa(students, AbstractDict) || return trained

    for (student, record) in students
        isa(record, AbstractDict) || continue
        by_kind = Dict{Symbol,Set{String}}()
        for kind in NAME_IMAGE_KINDS
            by_bucket = get(record, String(kind), nothing)
            isa(by_bucket, AbstractDict) || continue
            ids = Set{String}()
            for bucket in ("enroll", "query")
                values_for_bucket = get(by_bucket, bucket, nothing)
                isa(values_for_bucket, AbstractVector) || continue
                for id in values_for_bucket
                    push!(ids, String(id))
                end
            end
            by_kind[kind] = ids
        end
        trained[String(student)] = by_kind
    end
    return trained
end

"""
    class_name_data_summary(class_name)

Everything the Name Recognition screen needs to decide what it can offer: what
is stored, whether a `.namereader` exists, and how much of the stored data the
existing `.namereader` has never seen.
"""
function class_name_data_summary(class_name::AbstractString)::Dict{String,Any}
    name = sanitize_class_name(class_name)
    stored = scan_class_name_images(name)
    namereader = class_namereader_path(name)
    sidecar_path = class_namereader_sidecar_path(name)
    has_namereader = isfile(namereader)
    sidecar = has_namereader ? read_training_sidecar(sidecar_path) : nothing
    trained = _trained_ids(sidecar)

    counts = Dict(kind => 0 for kind in NAME_IMAGE_KINDS)
    new_counts = Dict(kind => 0 for kind in NAME_IMAGE_KINDS)
    new_students = String[]
    for (student, by_kind) in stored
        student_trained = get(trained, student, nothing)
        student_trained === nothing && !isempty(trained) && push!(new_students, student)
        for kind in NAME_IMAGE_KINDS
            ids = by_kind[kind]
            counts[kind] += length(ids)
            seen = student_trained === nothing ?
                Set{String}() : get(student_trained, kind, Set{String}())
            new_counts[kind] += count(id -> !(id in seen), ids)
        end
    end

    return Dict{String,Any}(
        "class_name" => name,
        "roster_csv" => class_csv_path(name),
        "data_dir" => class_name_data_dir(name),
        "images_dir" => class_name_images_dir(name),
        "num_students" => length(stored),
        "num_table_images" => counts[:table],
        "num_assn_images" => counts[:assn],
        "namereader_path" => namereader,
        "has_namereader" => has_namereader,
        "trained_at" => sidecar === nothing ? nothing : get(sidecar, "trained_at", nothing),
        "trained_students" => length(trained),
        "new_table_images" => has_namereader ? new_counts[:table] : 0,
        "new_assn_images" => has_namereader ? new_counts[:assn] : 0,
        "new_students" => has_namereader ? sort(new_students) : String[],
    )
end

# Roster names keyed by store folder, so `smith_john` can be shown as "Smith, John".
function _roster_names_by_folder(class_name::AbstractString)::Dict{String,String}
    names = Dict{String,String}()
    csv = class_csv_path(class_name)
    isfile(csv) || return names
    table = try
        read_roster_table(csv)
    catch
        return names
    end
    for student in table.Student
        folder = try
            sanitize_student_folder_name(student)
        catch
            continue
        end
        names[folder] = String(student)
    end
    return names
end

function _student_folders(images_root::AbstractString)::Vector{String}
    isdir(images_root) || return String[]
    return [e for e in readdir(images_root) if !startswith(e, ".") && isdir(joinpath(images_root, e))]
end

# Last training run's split as `student => kind => (id => "train" | "test")`.
function _trained_splits(sidecar)::Dict{String,Dict{Symbol,Dict{String,String}}}
    splits = Dict{String,Dict{Symbol,Dict{String,String}}}()
    isa(sidecar, AbstractDict) || return splits
    students = get(sidecar, "students", nothing)
    isa(students, AbstractDict) || return splits
    for (student, record) in students
        isa(record, AbstractDict) || continue
        by_kind = Dict{Symbol,Dict{String,String}}()
        for kind in NAME_IMAGE_KINDS
            by_bucket = get(record, String(kind), nothing)
            isa(by_bucket, AbstractDict) || continue
            ids = Dict{String,String}()
            for (bucket, split) in (("enroll", "train"), ("query", "test"))
                values_for_bucket = get(by_bucket, bucket, nothing)
                isa(values_for_bucket, AbstractVector) || continue
                for id in values_for_bucket
                    ids[String(id)] = split
                end
            end
            by_kind[kind] = ids
        end
        splits[String(student)] = by_kind
    end
    return splits
end

"""
    class_name_images_listing(class_name)

Every stored image per student for the Validate Data view, each tagged with the
split the last training run put it in (`nothing` when it has not been trained
on), plus every student an image may be reassigned to: the roster and anyone
already in the store.
"""
function class_name_images_listing(class_name::AbstractString)::Dict{String,Any}
    name = sanitize_class_name(class_name)
    images_root = class_name_images_dir(name)
    has_namereader = isfile(class_namereader_path(name))
    splits = _trained_splits(has_namereader ? read_training_sidecar(class_namereader_sidecar_path(name)) : nothing)
    roster = _roster_names_by_folder(name)
    display_name(folder) = get(roster, folder, folder)

    students = Dict{String,Any}[]
    for folder in _student_folders(images_root)
        student_splits = get(splits, folder, Dict{Symbol,Dict{String,String}}())
        images = Dict{String,Any}[]
        for file in sort(readdir(joinpath(images_root, folder)))
            endswith(lowercase(file), ".png") || continue
            kind = name_image_kind(file)
            split = get(get(student_splits, kind, Dict{String,String}()), name_image_id(file), nothing)
            push!(images, Dict{String,Any}("file" => file, "kind" => String(kind), "split" => split))
        end
        isempty(images) && continue
        push!(students, Dict{String,Any}("folder" => folder, "name" => display_name(folder), "images" => images))
    end
    sort!(students; by=s -> lowercase(s["name"]))

    targets = [Dict{String,Any}("folder" => f, "name" => display_name(f))
               for f in union(keys(roster), _student_folders(images_root))]
    sort!(targets; by=t -> lowercase(t["name"]))
    return Dict{String,Any}(
        "class_name" => name,
        "has_namereader" => has_namereader,
        "students" => students,
        "targets" => targets,
    )
end

"""
    class_name_image_file(class_name, student, file)

Path of a stored image named by the UI. Only exact entries of the store are
accepted, so a request can never reach a file outside it.
"""
function class_name_image_file(class_name::AbstractString, student::AbstractString, file::AbstractString)::String
    images_root = class_name_images_dir(class_name)
    student in _student_folders(images_root) || throw(ArgumentError("No stored images for $(repr(student))."))
    student_dir = joinpath(images_root, student)
    (endswith(lowercase(file), ".png") && file in readdir(student_dir)) ||
        throw(ArgumentError("Image $(repr(file)) not found for $(repr(student))."))
    return joinpath(student_dir, file)
end

# Training reads every student folder as a label, so an emptied one must not linger.
function _remove_student_dir_if_empty(student_dir::AbstractString)
    isdir(student_dir) || return nothing
    any(e -> !startswith(e, "."), readdir(student_dir)) && return nothing
    rm(student_dir; recursive=true)
    return nothing
end

function delete_class_name_image!(class_name::AbstractString, student::AbstractString, file::AbstractString)
    path = class_name_image_file(class_name, student, file)
    rm(path)
    _remove_student_dir_if_empty(dirname(path))
    return nothing
end

"""
    reassign_class_name_image!(class_name, student, file, to_student)

Move a stored image to another student's folder. The file name is its content
hash, so if the target already holds the same pixels the image is just removed
from `student`.
"""
function reassign_class_name_image!(
    class_name::AbstractString,
    student::AbstractString,
    file::AbstractString,
    to_student::AbstractString,
)
    source = class_name_image_file(class_name, student, file)
    to_student == student && return nothing
    images_root = class_name_images_dir(class_name)
    allowed = union(keys(_roster_names_by_folder(class_name)), _student_folders(images_root))
    to_student in allowed || throw(ArgumentError("Unknown student $(repr(to_student))."))
    target_dir = joinpath(images_root, to_student)
    mkpath(target_dir)
    destination = joinpath(target_dir, file)
    isfile(destination) ? rm(source) : mv(source, destination)
    _remove_student_dir_if_empty(dirname(source))
    return nothing
end

"""
    class_namereader_for_guessing(class_name)

The class's `.namereader` path, or `nothing` when the class has no trained model
yet. Used to wire the Process Scans "guess student names" option without asking
the user for a file.
"""
function class_namereader_for_guessing(class_name)::Union{Nothing,String}
    isa(class_name, AbstractString) && !isempty(strip(String(class_name))) || return nothing
    path = try
        class_namereader_path(class_name)
    catch
        return nothing
    end
    return isfile(path) ? path : nothing
end

end # module

module Server

using Oxygen
using HTTP
using JSON
using CSV

using ..ArchiveUtils
using ..Commands
using ..GoogleDrive
using ..Classes
using ..GenerateAssnFiles
using ..ProcessScans
using ..NameReader
using ..Paths: package_root, resolve_under_workspace

export serve, serveparallel, terminate

const STATE = Dict{String, Any}(
    "assn_archive_path" => nothing,
    "temp_archive_dir" => nothing,
)

# On exit, fold any work in the unpacked temp dir back into the .assn archive it came from, then
# clean the temp dir up. If repacking fails for any reason, the temp dir is intentionally left in
# place so the work (which also lives in grading_data.json there) can be recovered next session.
atexit() do
    temp_dir = get(STATE, "temp_archive_dir", nothing)
    archive_path = get(STATE, "assn_archive_path", nothing)
    if isa(temp_dir, String) && isdir(temp_dir)
        repacked = false
        if isa(archive_path, String) && isfile(archive_path)
            try
                make_archive_from_dir(temp_dir, archive_path; rebuild=true)
                repacked = true
            catch e
                @warn "Failed to repack archive on exit; leaving temp dir in place" exception=e temp_dir
            end
        end
        if repacked
            rm(temp_dir; force=true, recursive=true)
        end
    end

    preview_dir = get(STATE, "preview_dir", nothing)
    if isa(preview_dir, String) && isdir(preview_dir)
        try
            rm(preview_dir; force=true, recursive=true)
        catch
        end
    end
end

include("ServerUtils.jl")

# Oxygen route macros mutate Oxygen's global router. That must happen at runtime: during
# package precompilation those mutations are discarded, which left GET / (and every API
# route) returning 404 after `using Biscuit`.
const _ROUTES_REGISTERED = Ref(false)

function _register_routes!()
    _ROUTES_REGISTERED[] && return
    include(joinpath(@__DIR__, "ServerRoutes.jl"))
    _ROUTES_REGISTERED[] = true
    return
end

"""
    serve(; host="127.0.0.1", port=8080, kwargs...)

Start the Oxygen HTTP server (blocking). Prefer:

    julia --project=. -e 'using Biscuit; Biscuit.serve()'
"""
function serve(; host="127.0.0.1", port=8080, kwargs...)
    _register_routes!()
    return Oxygen.serve(; host, port, kwargs...)
end

"""
    serveparallel(; host="127.0.0.1", port=8080, kwargs...)

Start the Oxygen HTTP server with parallel request handling (blocking).
"""
function serveparallel(; host="127.0.0.1", port=8080, kwargs...)
    _register_routes!()
    return Oxygen.serveparallel(; host, port, kwargs...)
end

const terminate = Oxygen.terminate

end # module

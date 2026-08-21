module Server

using Oxygen
using HTTP
using JSON
using CSV
using Dates

using ..ArchiveUtils
using ..Commands
using ..GoogleDrive
using ..Classes
using ..GenerateAssnFiles
using ..ProcessScans
using ..NameReader
using ..Paths: package_root, resolve_under_workspace, config_dir

export serve, serveparallel, terminate, julia_main

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

function _ensure_bundled_paths!()
    extra_bins = [
        normpath(joinpath(Sys.BINDIR, "..", "Resources", "bin")),
        normpath(joinpath(Sys.BINDIR, "..", "..", "Resources", "bin")),
        normpath(joinpath(Sys.BINDIR, "..", "bin")),
    ]
    extra_libs = [
        normpath(joinpath(Sys.BINDIR, "..", "lib")),
        normpath(joinpath(Sys.BINDIR, "..", "Resources", "lib")),
        normpath(joinpath(Sys.BINDIR, "..", "..", "Resources", "lib")),
    ]
    if Sys.isapple()
        append!(extra_bins, [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            joinpath(homedir(), ".cargo", "bin"),
            joinpath(homedir(), ".local", "bin"),
        ])
    end

    sep = Sys.iswindows() ? ";" : ":"
    curr_path = get(ENV, "PATH", "")
    for p in extra_bins
        if isdir(p) && !occursin(p, curr_path)
            curr_path = p * sep * curr_path
        end
    end
    if Sys.iswindows()
        for p in extra_libs
            if isdir(p) && !occursin(p, curr_path)
                curr_path = p * sep * curr_path
            end
        end
    elseif Sys.isapple()
        curr_dyld = get(ENV, "DYLD_LIBRARY_PATH", "")
        for p in extra_libs
            if isdir(p) && !occursin(p, curr_dyld)
                curr_dyld = isempty(curr_dyld) ? p : p * ":" * curr_dyld
            end
        end
        ENV["DYLD_LIBRARY_PATH"] = curr_dyld
    end
    ENV["PATH"] = curr_path
end

Base.@ccallable function julia_main()::Cint
    _ensure_bundled_paths!()
    println("Biscuit starting on http://127.0.0.1:8080")
    flush(stdout)
    try
        serve(host="127.0.0.1", port=8080)
    catch
        Base.invokelatest(Base.display_error, Base.catch_stack())
        return 1
    end
    return 0
end


# Oxygen's router is global process state: it does not survive package
# precompilation, so routes must be *registered* at runtime. The handler
# functions themselves live in `_register_routes!` (see ServerRoutes.jl),
# which is compiled into the PackageCompiler sysimage. A runtime `include`
# of that file would re-parse and re-JIT every route on each launch.
const _ROUTES_REGISTERED = Ref(false)

include("ServerRoutes.jl")

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

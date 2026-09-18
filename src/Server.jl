module Server

using Oxygen
using HTTP
using CSV
using Dates

using ..ArchiveUtils
using ..JsonIO
using ..Commands
using ..GoogleDrive
using ..Classes
using ..GenerateAssnFiles
using ..ProcessScans
using ..ScanInput
using ..NameReader
using ..NameStore
using ..Paths: package_root, resolve_under_workspace, config_dir

export serve, serveparallel, terminate, julia_main

const STATE = Dict{String, Any}(
    "assn_archive_path" => nothing,
    "temp_archive_dir" => nothing,
)
const PREVIEW_COMPILE_LOCK = ReentrantLock()

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

    try
        _cleanup_builder_preview_dir!()
    catch
    end

    pid_file = get(STATE, "pid_file", nothing)
    if isa(pid_file, String)
        try
            rm(pid_file; force=true)
        catch
        end
    end
end

### Single-instance takeover ###

# Biscuit binds a fixed port and keeps per-user state under ~/.config/biscuit, so an instance left
# behind by a closed terminal blocks the next launch. Each run records its pid for the port it
# claimed; the next run retires that pid first. Before signalling anything we re-read the live
# process's command line and require it to match what was recorded, so a pid that has since been
# recycled by an unrelated program is reported and skipped rather than killed.

_pid_file_path(port::Integer)::String = joinpath(config_dir(), "biscuit-$port.pid")

"""
Command line of `pid` as the OS reports it, or `nothing` when no such process is running.
"""
function _live_command_line(pid::Integer)::Union{Nothing,String}
    cmd = if Sys.iswindows()
        Cmd(["powershell", "-NoProfile", "-Command",
             "(Get-CimInstance Win32_Process -Filter 'ProcessId=$pid').CommandLine"])
    else
        Cmd(["ps", "-p", string(pid), "-o", "command="])
    end
    out = try
        read(cmd, String)
    catch
        return nothing # non-zero exit means no such pid
    end
    text = strip(out)
    return isempty(text) ? nothing : String(text)
end

function _write_pid_file(port::Integer)::String
    path = _pid_file_path(port)
    mkpath(dirname(path))
    open(path, "w") do f
        json_print(f, Dict{String, Any}(
            "pid" => getpid(),
            "port" => Int(port),
            # Captured through the same query used to re-identify the pid later, so the recorded
            # and live strings are directly comparable.
            "command" => something(_live_command_line(getpid()), ""),
            "started" => string(Dates.now()),
        ))
    end
    return path
end

function _signal_pid(pid::Integer, force::Bool)::Bool
    cmd = if Sys.iswindows()
        force ? Cmd(["taskkill", "/F", "/PID", string(pid)]) : Cmd(["taskkill", "/PID", string(pid)])
    else
        Cmd(["kill", force ? "-KILL" : "-TERM", string(pid)])
    end
    try
        run(pipeline(cmd; stdout=devnull, stderr=devnull))
        return true
    catch
        return false
    end
end

function _wait_for_exit(pid::Integer, seconds::Real)::Bool
    deadline = time() + seconds
    while time() < deadline
        _live_command_line(pid) === nothing && return true
        sleep(0.15)
    end
    return _live_command_line(pid) === nothing
end

function _retire_previous_instance!(port::Integer)::Nothing
    path = _pid_file_path(port)
    isfile(path) || return nothing
    record = try
        json_parsefile(path)
    catch
        rm(path; force=true)
        return nothing
    end
    raw_pid = get(record, "pid", nothing)
    if !isa(raw_pid, Integer)
        rm(path; force=true)
        return nothing
    end
    pid = Int(raw_pid)
    pid == getpid() && return nothing
    live = _live_command_line(pid)
    if live === nothing
        rm(path; force=true) # stale record, process already gone
        return nothing
    end
    recorded = String(get(record, "command", ""))
    if isempty(recorded) || live != recorded
        @warn "Ignoring stale Biscuit pid file: pid $pid now belongs to a different process" path
        rm(path; force=true)
        return nothing
    end
    println("Found a previous Biscuit instance (pid $pid) on port $port; shutting it down...")
    flush(stdout)
    # SIGTERM first so the atexit hook can fold in-progress grading back into the .assn archive.
    _signal_pid(pid, false)
    if !_wait_for_exit(pid, 5)
        println("  Previous instance did not exit on request; forcing it.")
        flush(stdout)
        _signal_pid(pid, true)
        _wait_for_exit(pid, 2)
    end
    if _live_command_line(pid) === nothing
        println("  Previous instance stopped.")
    else
        @warn "Could not stop the previous Biscuit instance; port $port may still be in use" pid
    end
    flush(stdout)
    rm(path; force=true)
    return nothing
end

# Never let pid bookkeeping stop a launch: a sandboxed or unusual environment that cannot run
# `ps` should still get a server.
function _claim_single_instance!(port::Integer)::Nothing
    try
        _retire_previous_instance!(port)
        STATE["pid_file"] = _write_pid_file(port)
    catch e
        @warn "Could not check for a previous Biscuit instance; continuing" exception=e
    end
    return nothing
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
    _claim_single_instance!(port)
    return Oxygen.serve(; host, port, kwargs...)
end

"""
    serveparallel(; host="127.0.0.1", port=8080, kwargs...)

Start the Oxygen HTTP server with parallel request handling (blocking).
"""
function serveparallel(; host="127.0.0.1", port=8080, kwargs...)
    _register_routes!()
    _claim_single_instance!(port)
    return Oxygen.serveparallel(; host, port, kwargs...)
end

const terminate = Oxygen.terminate

end # module

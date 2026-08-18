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

function _ensure_standard_mac_paths!()
    if Sys.isapple()
        extra_paths = [
            normpath(joinpath(Sys.BINDIR, "..", "Resources", "bin")),
            normpath(joinpath(Sys.BINDIR, "..", "..", "Resources", "bin")),
            normpath(joinpath(Sys.BINDIR, "..", "bin")),
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            joinpath(homedir(), ".cargo", "bin"),
            joinpath(homedir(), ".local", "bin"),
        ]
        curr_path = get(ENV, "PATH", "")
        for p in extra_paths
            if isdir(p) && !occursin(p, curr_path)
                curr_path = p * ":" * curr_path
            end
        end
        ENV["PATH"] = curr_path
    end
end

function _init_mac_dock_app!()
    Sys.isapple() || return
    try
        # 1. Load AppKit framework
        ccall((:NSApplicationLoad, "/System/Library/Frameworks/AppKit.framework/AppKit"), Cint, ())

        # 2. Get shared NSApplication instance
        cls_NSApp = ccall(:objc_getClass, Ptr{Cvoid}, (Cstring,), "NSApplication")
        sel_shared = ccall(:sel_registerName, Ptr{Cvoid}, (Cstring,), "sharedApplication")
        app = ccall(:objc_msgSend, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}), cls_NSApp, sel_shared)

        # 3. Set activation policy to Regular (0 = NSApplicationActivationPolicyRegular)
        # Keeps the Biscuit icon in the Dock with an active indicator dot & in Cmd+Tab switcher
        sel_setPolicy = ccall(:sel_registerName, Ptr{Cvoid}, (Cstring,), "setActivationPolicy:")
        ccall(:objc_msgSend, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Clong), app, sel_setPolicy, 0)

        # 4. Finish launching and activate
        sel_finish = ccall(:sel_registerName, Ptr{Cvoid}, (Cstring,), "finishLaunching")
        ccall(:objc_msgSend, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), app, sel_finish)

        sel_activate = ccall(:sel_registerName, Ptr{Cvoid}, (Cstring,), "activateIgnoringOtherApps:")
        ccall(:objc_msgSend, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Bool), app, sel_activate, true)
    catch
    end
end

function _mac_gui_setup!()
    Sys.isapple() || return
    _init_mac_dock_app!()

    # If run interactively in a terminal shell, keep standard terminal I/O and pwd()
    is_interactive = isa(stdin, Base.TTY) || (haskey(ENV, "TERM_PROGRAM") && isinteractive())
    if is_interactive
        return
    end

    # GUI double-click mode:
    config_d = config_dir()
    mkpath(config_d)
    last_ws_file = joinpath(config_d, "last_workspace.txt")
    log_file = joinpath(config_d, "biscuit.log")

    # 1. Check workspace folder (passed argument, drag-and-drop, or native folder picker)
    target_workspace = ""
    for arg in ARGS
        if isdir(arg)
            target_workspace = abspath(arg)
            break
        end
    end

    if isempty(target_workspace)
        default_opt = ""
        if isfile(last_ws_file)
            last_dir = strip(read(last_ws_file, String))
            if isdir(last_dir)
                default_opt = "default location POSIX file \"$last_dir\""
            end
        end

        script = """
        try
            set chosenFolder to choose folder with prompt "Select your Biscuit course workspace folder:" $default_opt
            POSIX path of chosenFolder
        on error
            return ""
        end try
        """
        try
            chosen = strip(read(pipeline(`osascript -e $script`), String))
            if isempty(chosen)
                exit(0) # User cancelled folder picker
            end
            target_workspace = chosen
        catch
            target_workspace = homedir()
        end
    end

    if isdir(target_workspace)
        try; write(last_ws_file, target_workspace); catch; end
        cd(target_workspace)
    end

    # 2. Log rotation: keep biscuit.log <= 5 MB
    try
        if isfile(log_file) && filesize(log_file) > 5 * 1024 * 1024
            lines = readlines(log_file)
            if length(lines) > 5000
                open(log_file, "w") do f
                    for l in lines[end-5000:end]
                        println(f, l)
                    end
                end
            end
        end
    catch
    end

    # 3. Redirect stdout & stderr to biscuit.log
    try
        open(log_file, "a") do f
            println(f, "============================================================")
            println(f, "  Biscuit started at ", Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"))
            println(f, "  Workspace: ", pwd())
            println(f, "  URL:       http://127.0.0.1:8080")
            println(f, "============================================================")
        end
        log_io = open(log_file, "a")
        redirect_stdout(log_io)
        redirect_stderr(log_io)
    catch
    end
end

Base.@ccallable function julia_main()::Cint
    _ensure_standard_mac_paths!()
    if Sys.isapple()
        _mac_gui_setup!()
        @async begin
            sleep(0.8)
            try; run(`open http://127.0.0.1:8080`); catch; end
        end
    end
    try
        serve(host="127.0.0.1", port=8080)
    catch
        Base.invokelatest(Base.display_error, Base.catch_stack())
        return 1
    end
    return 0
end


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

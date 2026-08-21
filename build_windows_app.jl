# build_windows_app.jl
# Automated script to build a standalone, double-clickable Biscuit app for Windows.
# Run this on a Windows machine (PackageCompiler does not cross-compile).

using Pkg

# Load PackageCompiler from the global/shared environment
# so it never pollutes Biscuit's Project.toml
try
    using PackageCompiler
catch
    pushfirst!(LOAD_PATH, "@v#.#")
    try
        using PackageCompiler
    catch
        println("PackageCompiler not found. Installing into global Julia environment...")
        Pkg.activate()
        Pkg.add("PackageCompiler")
        using PackageCompiler
    end
end

const APP_NAME = "Biscuit"
const BACKEND_NAME = "biscuit-server"
const BUILD_DIR = joinpath(@__DIR__, "build")
const RAW_APP_DIR = joinpath(BUILD_DIR, "$(APP_NAME)_raw")
const FINAL_APP_DIR = joinpath(BUILD_DIR, APP_NAME)

println("=== Building $APP_NAME for Windows ===")

# 1. Clean previous build artifacts
rm(RAW_APP_DIR; force=true, recursive=true)
rm(FINAL_APP_DIR; force=true, recursive=true)
mkpath(BUILD_DIR)

# 2. Precompile and build the standalone backend binary with PackageCompiler
println("--> Running PackageCompiler (compiling sysimage and C runtime)...")
workload_file = joinpath(@__DIR__, "precompile_workload.jl")
create_app_kwargs = Dict{Symbol, Any}(
    :executables => [BACKEND_NAME => "julia_main"],
    :force => true,
    :include_lazy_artifacts => true,
)
if isfile(workload_file)
    create_app_kwargs[:precompile_execution_file] = workload_file
end

PackageCompiler.create_app(
    @__DIR__,
    RAW_APP_DIR;
    create_app_kwargs...,
)

# 3. Construct application directory structure
println("--> Assembling Windows application directory ($FINAL_APP_DIR)...")
app_runtime_dir = joinpath(FINAL_APP_DIR, "app")
resources_dir = joinpath(FINAL_APP_DIR, "Resources")

mkpath(app_runtime_dir)
mkpath(resources_dir)

for item in readdir(RAW_APP_DIR)
    mv(joinpath(RAW_APP_DIR, item), joinpath(app_runtime_dir, item))
end
rm(RAW_APP_DIR; force=true, recursive=true)

# 4. Copy static assets into Resources
println("--> Copying non-Julia assets (public/, templates, configs)...")
cp(joinpath(@__DIR__, "public"), joinpath(resources_dir, "public"); force=true)

if isdir(joinpath(@__DIR__, "typst_doc_generators"))
    cp(joinpath(@__DIR__, "typst_doc_generators"), joinpath(resources_dir, "typst_doc_generators"); force=true)
end

if isfile(joinpath(@__DIR__, "google_drive_client.json"))
    cp(joinpath(@__DIR__, "google_drive_client.json"), joinpath(resources_dir, "google_drive_client.json"); force=true)
end

bg_images_dir = joinpath(@__DIR__, "src", "NameReader", "background_training_images")
if isdir(bg_images_dir)
    cp(bg_images_dir, joinpath(resources_dir, "background_training_images"); force=true)
end

# Copy icon (used as the launcher / console / taskbar icon)
ico_source = joinpath(@__DIR__, "public", "favicon.ico")
ico_dest = joinpath(resources_dir, "Biscuit.ico")
if isfile(ico_source)
    cp(ico_source, ico_dest; force=true)
end

# Bundle local libdmtx.dll if present
println("--> Checking for local libdmtx library...")
dmtx_candidates = [
    joinpath(dirname(Sys.BINDIR), "lib", "libdmtx.dll"),
    joinpath(dirname(Sys.BINDIR), "bin", "libdmtx.dll"),
    "C:\\Program Files\\libdmtx\\libdmtx.dll",
    "C:\\msys64\\mingw64\\bin\\libdmtx.dll",
]
found_dmtx = nothing
for cand in dmtx_candidates
    if isfile(cand)
        global found_dmtx = cand
        break
    end
end
which_dmtx = Sys.which("libdmtx.dll")
if found_dmtx === nothing && which_dmtx !== nothing && isfile(which_dmtx)
    found_dmtx = which_dmtx
end
if found_dmtx !== nothing
    app_lib_dir = joinpath(app_runtime_dir, "lib")
    res_lib_dir = joinpath(resources_dir, "lib")
    mkpath(app_lib_dir)
    mkpath(res_lib_dir)
    cp(found_dmtx, joinpath(app_lib_dir, basename(found_dmtx)); force=true)
    cp(found_dmtx, joinpath(res_lib_dir, basename(found_dmtx)); force=true)
    println("    ✓ Bundled libdmtx from $found_dmtx")
else
    @warn "libdmtx.dll not found; Process Scans will fail until it is installed and rebundled."
end

# Bundle local typst.exe if present
println("--> Checking for local Typst executable...")
typst_bin = Sys.which("typst")
if typst_bin !== nothing && isfile(typst_bin)
    res_bin_dir = joinpath(resources_dir, "bin")
    mkpath(res_bin_dir)
    dest_typst = joinpath(res_bin_dir, "typst.exe")
    cp(typst_bin, dest_typst; force=true)
    println("    ✓ Bundled typst from $typst_bin")
else
    @warn "typst.exe not found in PATH; assignment PDF generation will fail until it is installed and rebundled."
end

# 5. Compile Windows launcher (folder picker + minimized console + browser)
println("--> Compiling native Windows launcher (Biscuit.exe)...")
launcher_src = joinpath(@__DIR__, "src", "windows_launcher.cs")
launcher_dest = joinpath(FINAL_APP_DIR, "$APP_NAME.exe")

windir = get(ENV, "WINDIR", "C:\\Windows")
csc_candidates = [
    Sys.which("csc"),
    joinpath(windir, "Microsoft.NET", "Framework64", "v4.0.30319", "csc.exe"),
    joinpath(windir, "Microsoft.NET", "Framework", "v4.0.30319", "csc.exe"),
]
found_csc = nothing
for cand in csc_candidates
    if cand !== nothing && isfile(cand)
        global found_csc = cand
        break
    end
end

if found_csc !== nothing
    icon_args = isfile(ico_dest) ? ["/win32icon:$ico_dest"] : String[]
    compile_cmd = Cmd([
        found_csc,
        "/nologo",
        "/target:winexe",
        "/optimize+",
        icon_args...,
        "/out:$launcher_dest",
        launcher_src,
    ])
    run(compile_cmd)
    println("    ✓ Compiled Biscuit.exe using $found_csc")
else
    @warn "csc.exe (C# compiler) not found. Install .NET Framework 4.x or add csc.exe to PATH, then re-run."
end

println("""
============================================================
✓ SUCCESS! Standalone Windows App built successfully:
  $FINAL_APP_DIR

Directory Layout:
  $FINAL_APP_DIR/
    Biscuit.exe          <- Double-click this to run
    Resources/           <- Web frontend, icon, bundled typst/libdmtx
    app/                 <- Julia backend runtime (biscuit-server.exe)

Behavior:
- Folder picker on launch (remembers the last workspace)
- Backend console uses the Biscuit icon, starts minimized
- Browser opens http://127.0.0.1:8080 once the server is ready
- Restore the taskbar icon to see backend logs; close it to stop the server
- Logs are also written to %USERPROFILE%\\.config\\biscuit\\biscuit.log
============================================================
""")

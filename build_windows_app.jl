# build_windows_app.jl
# Automated script to build a standalone, system-tray Biscuit app for Windows.

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
const BUILD_DIR = joinpath(@__DIR__, "build")
const RAW_APP_DIR = joinpath(BUILD_DIR, "$(APP_NAME)_raw")
const FINAL_APP_DIR = joinpath(BUILD_DIR, APP_NAME)

println("=== Building $APP_NAME for Windows ===")

# 1. Clean previous build artifacts
rm(RAW_APP_DIR; force=true, recursive=true)
rm(FINAL_APP_DIR; force=true, recursive=true)
mkpath(BUILD_DIR)

# 2. Precompile and build the standalone app binary with PackageCompiler
println("--> Running PackageCompiler (compiling sysimage and C runtime)...")
workload_file = joinpath(@__DIR__, "precompile_workload.jl")
create_app_kwargs = Dict{Symbol, Any}(
    :executables => [APP_NAME => "julia_main"],
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

# Copy icon
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
]
found_dmtx = nothing
for cand in dmtx_candidates
    if isfile(cand)
        global found_dmtx = cand
        break
    end
end
if found_dmtx !== nothing
    app_lib_dir = joinpath(app_runtime_dir, "lib")
    res_lib_dir = joinpath(resources_dir, "lib")
    mkpath(app_lib_dir)
    mkpath(res_lib_dir)
    cp(found_dmtx, joinpath(app_lib_dir, basename(found_dmtx)); force=true)
    cp(found_dmtx, joinpath(res_lib_dir, basename(found_dmtx)); force=true)
    println("    ✓ Bundled libdmtx from $found_dmtx")
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
end

# 5. Compile Windows System Tray Launcher (using built-in csc.exe)
println("--> Compiling native Windows System Tray Launcher (Biscuit.exe)...")
launcher_src = joinpath(@__DIR__, "src", "windows_launcher.cs")
launcher_dest = joinpath(FINAL_APP_DIR, "$APP_NAME.exe")

# Locate C# compiler (pre-installed on all Windows versions)
csc_candidates = [
    Sys.which("csc"),
    "C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe",
    "C:\\Windows\\Microsoft.NET\\Framework\\v4.0.30319\\csc.exe",
]
found_csc = nothing
for cand in csc_candidates
    if cand !== nothing && isfile(cand)
        global found_csc = cand
        break
    end
end

if found_csc !== nothing
    icon_arg = isfile(ico_dest) ? "/win32icon:\"$ico_dest\"" : ""
    compile_cmd = `$found_csc /target:winexe /optimize+ /r:System.Net.Http.dll $icon_arg /out:"$launcher_dest" "$launcher_src"`
    run(compile_cmd)
    println("    ✓ Compiled Biscuit.exe using $found_csc")
else
    @warn "csc.exe (C# compiler) not found. Please compile src/windows_launcher.cs manually."
end

println("""
============================================================
✓ SUCCESS! Standalone Windows App built successfully:
  $FINAL_APP_DIR

Directory Layout:
  $FINAL_APP_DIR/
    Biscuit.exe          <- Double-click this to run (System Tray App)
    Resources/           <- Web frontend & assets
    app/                 <- Backend runtime

Features:
- System Tray: Runs quietly in the notification area next to the clock
- Menu: Right-click icon for Web UI, Course Workspace, Logs, or Exit
- Browser: Opens http://127.0.0.1:8080 automatically when ready
============================================================
""")

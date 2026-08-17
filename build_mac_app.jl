# build_mac_app.jl
# Automated script to build a standalone, double-clickable Biscuit.app on macOS.

using Pkg

if !haskey(Pkg.project().dependencies, "PackageCompiler")
    println("Adding PackageCompiler...")
    Pkg.add("PackageCompiler")
end

using PackageCompiler

const APP_NAME = "Biscuit"
const BUNDLE_NAME = "$APP_NAME.app"
const BUILD_DIR = joinpath(@__DIR__, "build")
const RAW_APP_DIR = joinpath(BUILD_DIR, "$(APP_NAME)_raw")
const FINAL_APP_DIR = joinpath(BUILD_DIR, BUNDLE_NAME)

println("=== Building $BUNDLE_NAME for macOS ===")

# 1. Clean previous build artifacts
rm(RAW_APP_DIR; force=true, recursive=true)
rm(FINAL_APP_DIR; force=true, recursive=true)
mkpath(BUILD_DIR)

# 2. Generate macOS .icns icon from public/biscuit.png
println("--> Generating native macOS .icns app icon...")
icon_tmp_dir = mktempdir()
iconset_dir = joinpath(icon_tmp_dir, "biscuit.iconset")
mkpath(iconset_dir)
png_source = joinpath(@__DIR__, "public", "biscuit.png")

if isfile(png_source)
    run(`sips -z 16 16 "$png_source" --out $(joinpath(iconset_dir, "icon_16x16.png"))`)
    run(`sips -z 32 32 "$png_source" --out $(joinpath(iconset_dir, "icon_16x16@2x.png"))`)
    run(`sips -z 32 32 "$png_source" --out $(joinpath(iconset_dir, "icon_32x32.png"))`)
    run(`sips -z 64 64 "$png_source" --out $(joinpath(iconset_dir, "icon_32x32@2x.png"))`)
    run(`sips -z 128 128 "$png_source" --out $(joinpath(iconset_dir, "icon_128x128.png"))`)
    run(`sips -z 256 256 "$png_source" --out $(joinpath(iconset_dir, "icon_128x128@2x.png"))`)
    run(`sips -z 256 256 "$png_source" --out $(joinpath(iconset_dir, "icon_256x256.png"))`)
    run(`sips -z 512 512 "$png_source" --out $(joinpath(iconset_dir, "icon_256x256@2x.png"))`)
    run(`sips -z 512 512 "$png_source" --out $(joinpath(iconset_dir, "icon_512x512.png"))`)
    
    icns_path = joinpath(icon_tmp_dir, "Biscuit.icns")
    run(`iconutil -c icns "$iconset_dir" -o "$icns_path"`)
else
    @warn "public/biscuit.png not found; icon generation skipped."
    icns_path = nothing
end

# 3. Precompile and build the standalone app binary with PackageCompiler
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

# 4. Construct macOS .app bundle directory structure
println("--> Assembling macOS application bundle ($FINAL_APP_DIR)...")
contents_dir = joinpath(FINAL_APP_DIR, "Contents")
macos_dir = joinpath(contents_dir, "MacOS")
resources_dir = joinpath(contents_dir, "Resources")
app_runtime_dir = joinpath(contents_dir, "app")

mkpath(macos_dir)
mkpath(resources_dir)
mkpath(app_runtime_dir)

for item in readdir(RAW_APP_DIR)
    mv(joinpath(RAW_APP_DIR, item), joinpath(app_runtime_dir, item))
end
rm(RAW_APP_DIR; force=true, recursive=true)

# Copy static assets into Contents/Resources
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

# Bundle local libdmtx.dylib
println("--> Bundling local libdmtx dynamic library...")
dmtx_candidates = [
    "/usr/local/lib/libdmtx.dylib",
    "/opt/homebrew/lib/libdmtx.dylib",
    "/usr/lib/libdmtx.dylib",
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
    # Copy libdmtx and any matching dylib files
    src_dir = dirname(found_dmtx)
    for f in readdir(src_dir)
        if startswith(f, "libdmtx") && occursin(".dylib", f)
            src_f = joinpath(src_dir, f)
            isfile(src_f) || continue
            cp(src_f, joinpath(app_lib_dir, f); force=true)
            cp(src_f, joinpath(res_lib_dir, f); force=true)
        end
    end
    println("    ✓ Bundled libdmtx from $found_dmtx")
else
    @warn "libdmtx.dylib not found in standard paths; skipped bundling."
end

# Bundle local typst binary
println("--> Bundling local Typst executable...")
typst_bin = Sys.which("typst")
if typst_bin !== nothing && isfile(typst_bin)
    res_bin_dir = joinpath(resources_dir, "bin")
    mkpath(res_bin_dir)
    dest_typst = joinpath(res_bin_dir, "typst")
    cp(typst_bin, dest_typst; force=true)
    chmod(dest_typst, 0o755)
    println("    ✓ Bundled typst from $typst_bin")
else
    @warn "typst binary not found in PATH; skipped bundling."
end

if icns_path !== nothing && isfile(icns_path)
    cp(icns_path, joinpath(resources_dir, "Biscuit.icns"); force=true)
    rm(icon_tmp_dir; force=true, recursive=true)
end

# 5. Create launcher script at Contents/MacOS/Biscuit
launcher_script = joinpath(macos_dir, APP_NAME)
open(launcher_script, "w") do f
    write(f, """
    #!/bin/bash
    DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
    APP_DIR="\$(cd "\$DIR/.." && pwd)"

    # Prepend bundled binaries and dynamic libraries
    export PATH="\$APP_DIR/Resources/bin:\$APP_DIR/app/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:\$HOME/.cargo/bin:\$HOME/.local/bin:\$PATH"
    export DYLD_LIBRARY_PATH="\$APP_DIR/app/lib:\$APP_DIR/Resources/lib:\$DYLD_LIBRARY_PATH"

    exec "\$APP_DIR/app/bin/$APP_NAME" "\$@"
    """)
end
chmod(launcher_script, 0o755)

# 6. Create Info.plist
open(joinpath(contents_dir, "Info.plist"), "w") do f
    write(f, """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleExecutable</key>
        <string>$APP_NAME</string>
        <key>CFBundleIconFile</key>
        <string>Biscuit.icns</string>
        <key>CFBundleIdentifier</key>
        <string>com.biscuit.app</string>
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>CFBundleName</key>
        <string>$APP_NAME</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleShortVersionString</key>
        <string>0.1.0</string>
        <key>CFBundleVersion</key>
        <string>1</string>
        <key>NSHighResolutionCapable</key>
        <true/>
        <key>LSMinimumSystemVersion</key>
        <string>11.0</string>
    </dict>
    </plist>
    """)
end

# 7. Create PkgInfo
open(joinpath(contents_dir, "PkgInfo"), "w") do f
    write(f, "APPL????")
end

println("""
============================================================
✓ SUCCESS! Standalone Mac App built successfully:
  $FINAL_APP_DIR

You can double-click Biscuit.app in Finder or move it to /Applications:
  cp -r "$FINAL_APP_DIR" /Applications/
============================================================
""")

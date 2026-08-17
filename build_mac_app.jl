# build_mac_app.jl
# Automated script to build a standalone, double-clickable Biscuit.app on macOS.

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
iconset_dir = joinpath(icon_tmp_dir, "Biscuit.iconset")
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
    run(`sips -z 1024 1024 "$png_source" --out $(joinpath(iconset_dir, "icon_512x512@2x.png"))`)
    
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

    CONFIG_DIR="\$HOME/.config/biscuit"
    LAST_WS_FILE="\$CONFIG_DIR/last_workspace.txt"
    LOG_FILE="\$CONFIG_DIR/biscuit.log"
    mkdir -p "\$CONFIG_DIR"

    # Interactive CLI mode (when invoked directly from a terminal shell)
    if [ -t 0 ] || [ -n "\$TERM_PROGRAM" ]; then
        if [ -n "\$1" ] && [ -d "\$1" ]; then
            cd "\$1" || exit 1
        fi
        exec "\$APP_DIR/app/bin/$APP_NAME" "\$@"
    fi

    # Finder / GUI double-click mode:
    # 1. Determine workspace directory (passed argument, drag-and-drop, or folder picker)
    WORKSPACE="\$1"

    if [ -z "\$WORKSPACE" ] || [ ! -d "\$WORKSPACE" ]; then
        DEFAULT_OPT=""
        if [ -f "\$LAST_WS_FILE" ]; then
            LAST_DIR=\$(cat "\$LAST_WS_FILE")
            if [ -d "\$LAST_DIR" ]; then
                DEFAULT_OPT="default location POSIX file \\\"\$LAST_DIR\\\""
            fi
        fi

        CHOSEN=\$(osascript -e "try
            set chosenFolder to choose folder with prompt \\\"Select your Biscuit course workspace folder:\\\" \$DEFAULT_OPT
            POSIX path of chosenFolder
        on error
            return \\\"\\\"
        end try" 2>/dev/null)

        if [ -z "\$CHOSEN" ]; then
            exit 0
        fi
        WORKSPACE="\$CHOSEN"
    fi

    # Save chosen workspace and change directory
    echo "\$WORKSPACE" > "\$LAST_WS_FILE"
    cd "\$WORKSPACE" || exit 1

    # Log session startup
    echo "============================================================" >> "\$LOG_FILE"
    echo "  Biscuit started at \$(date)" >> "\$LOG_FILE"
    echo "  Workspace: \$(pwd)" >> "\$LOG_FILE"
    echo "  URL:       http://127.0.0.1:8080" >> "\$LOG_FILE"
    echo "============================================================" >> "\$LOG_FILE"

    # Execute backend silently, redirecting output to log file
    exec "\$APP_DIR/app/bin/$APP_NAME" >> "\$LOG_FILE" 2>&1
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
        <key>CFBundleIconName</key>
        <string>Biscuit</string>
        <key>CFBundleIdentifier</key>
        <string>com.biscuit.app</string>
        <key>CFBundleInfoDictionaryVersion</key>
        <string>6.0</string>
        <key>CFBundleName</key>
        <string>$APP_NAME</string>
        <key>CFBundleDisplayName</key>
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
        <key>CFBundleDocumentTypes</key>
        <array>
            <dict>
                <key>CFBundleTypeName</key>
                <string>Folder</string>
                <key>CFBundleTypeRole</key>
                <string>Viewer</string>
                <key>LSItemContentTypes</key>
                <array>
                    <string>public.folder</string>
                </array>
            </dict>
        </array>
    </dict>
    </plist>
    """)
end

# 7. Create PkgInfo
open(joinpath(contents_dir, "PkgInfo"), "w") do f
    write(f, "APPL????")
end

# 8. Refresh macOS LaunchServices icon & bundle registration
println("--> Refreshing macOS icon & bundle cache...")
try
    run(`touch "$FINAL_APP_DIR"`)
    lsreg = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    if isfile(lsreg)
        run(`$lsreg -f "$FINAL_APP_DIR"`)
    end
catch
end

println("""
============================================================
✓ SUCCESS! Standalone Mac App built successfully:
  $FINAL_APP_DIR

- Icon: Set to Biscuit icon (with full Retina resolutions)
- Dock: Shows in Dock without bouncing
- Web UI: Opens http://127.0.0.1:8080 automatically
- Workspace: Interactive folder picker on launch (or drag & drop)
- Logs: Terminal is hidden, logs saved to ~/.config/biscuit/biscuit.log

You can double-click Biscuit.app in Finder or move it to /Applications:
  cp -r "$FINAL_APP_DIR" /Applications/
============================================================
""")

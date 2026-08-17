module Paths

export package_root
export config_dir
export workspace_root
export is_under_workspace
export resolve_under_workspace

"""
Directory containing `Project.toml`, `public/`, and `typst_doc_generators/`.
Dynamically resolves to macOS app bundle Resources, PackageCompiler share dir, or source root.
"""
function package_root()::String
    # 1. macOS app bundle: <AppName>.app/Contents/Resources (via Contents/app/bin or Contents/MacOS)
    res_parent = normpath(joinpath(Sys.BINDIR, "..", "..", "Resources"))
    if isdir(res_parent) && isfile(joinpath(res_parent, "public", "index.html"))
        return res_parent
    end

    res_direct = normpath(joinpath(Sys.BINDIR, "..", "Resources"))
    if isdir(res_direct) && isfile(joinpath(res_direct, "public", "index.html"))
        return res_direct
    end

    # 2. Standalone PackageCompiler app: <AppDir>/share/biscuit
    app_share = normpath(joinpath(Sys.BINDIR, "..", "share", "biscuit"))
    if isdir(app_share) && isfile(joinpath(app_share, "public", "index.html"))
        return app_share
    end

    # 3. Standalone PackageCompiler app root: <AppDir>
    app_root = normpath(joinpath(Sys.BINDIR, ".."))
    if isdir(app_root) && isfile(joinpath(app_root, "public", "index.html"))
        return app_root
    end

    # 4. Fallback to package source tree (during development)
    return normpath(joinpath(@__DIR__, ".."))
end

"""
Per-user app config (`google_drive_token.json`, `classes/`). Not course data.
"""
config_dir()::String = joinpath(homedir(), ".config", "biscuit")

"""
Caller's working directory: assignment inputs/outputs stay here.
"""
workspace_root()::String = abspath(pwd())

function is_under_workspace(path::AbstractString; root::AbstractString=workspace_root())::Bool
    root_n = normpath(abspath(root))
    path_n = normpath(abspath(path))
    root_n == path_n && return true
    prefix = root_n * Base.Filesystem.path_separator
    return startswith(path_n, prefix)
end

"""
Resolve `path` against the workspace. Rejects absolute paths and `..` escapes.
Returns a path relative to the workspace when possible (`.` for the root).
"""
function resolve_under_workspace(path::AbstractString; root::AbstractString=workspace_root())::String
    raw = strip(String(path))
    isempty(raw) && return "."
    isabspath(raw) && throw(ArgumentError("Path must be inside the workspace, not absolute: $(repr(raw))"))
    root_n = normpath(abspath(root))
    resolved = normpath(joinpath(root_n, raw))
    is_under_workspace(resolved; root=root_n) || throw(ArgumentError(
        "Path escapes the workspace: $(repr(raw))"
    ))
    rel = relpath(resolved, root_n)
    return rel == "." ? "." : replace(rel, "\\" => "/")
end

end # module

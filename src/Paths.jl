module Paths

export package_root
export config_dir
export workspace_root
export is_under_workspace
export resolve_under_workspace

"""
Directory containing `Project.toml`, `public/`, and `typst_doc_generators/`.
"""
package_root()::String = normpath(joinpath(@__DIR__, ".."))

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

module Biscuit

"""
    Biscuit

Julia package for the Biscuit assignment workflow.

Start from a course workspace (masters, scans, archives):

    julia --project=/path/to/024-exam_generator -e 'using Biscuit; Biscuit.serve()'

System dependencies (not Julia packages): Typst on `PATH`, and libdmtx plus whatever
native libraries OpenCV.jl needs for your OS (`brew install libdmtx` on macOS;
`libdmtx0t64` / `libdmtx-dev` on Debian/Ubuntu). PDF scans are rasterized with
the bundled `Poppler_jll` (`pdftoppm`); no system Poppler install is required.

Templates and static files live in the package (`package_root()`). Per-user credentials
live under `~/.config/biscuit/`. Assignment inputs/outputs stay in `pwd()`.

Name-image matching lives in the `NameReader` submodule (`Biscuit.NameReader`).
"""

include("Paths.jl")
using .Paths

include("JsonIO.jl")
using .JsonIO

include("ArchiveUtils.jl")
using .ArchiveUtils

include("Commands.jl")
using .Commands

include("Classes.jl")
using .Classes

include("GoogleDrive.jl")
using .GoogleDrive

include("Dmtx.jl")
using .Dmtx

include("GenerateAssnFiles.jl")
using .GenerateAssnFiles

include("NameReader/NameReader.jl")
using .NameReader

include("NameStore.jl")
using .NameStore

include("ScanInput.jl")
using .ScanInput

include("ProcessScans.jl")
using .ProcessScans

include("Server.jl")
using .Server

export package_root, config_dir, workspace_root
export serve, serveparallel, terminate, julia_main
export generate_assn_files, process_scans, extract_name_field_crops
export NameReader
export ScanInput
export train_name_reader

end # module

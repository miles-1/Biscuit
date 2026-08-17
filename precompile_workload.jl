# precompile_workload.jl
# Runs typical workloads during compilation to pre-warm method caches.

using Biscuit
using HTTP
using JSON
using JSON3
using CSV

# Path resolution
_ = Biscuit.package_root()
_ = Biscuit.config_dir()
_ = Biscuit.workspace_root()

# Register routes
Biscuit.Server._register_routes!()

# JSON & CSV parsing
sample_json = JSON.json(Dict("status" => "ok", "items" => [1, 2, 3]))
_ = JSON.parse(sample_json)

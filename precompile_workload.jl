# precompile_workload.jl
# Runs typical workloads during compilation to pre-warm method caches and JIT specializations.

using Biscuit
using HTTP
using JSON
using JSON3
using CSV
using YAML

# 1. Path resolution
_ = Biscuit.package_root()
_ = Biscuit.config_dir()
_ = Biscuit.workspace_root()

# 2. Register routes and warm up Oxygen HTTP request pipeline
Biscuit.Server._register_routes!()

try
    _ = Biscuit.Server.Oxygen.internalrequest(HTTP.Request("GET", "/"))
    _ = Biscuit.Server.Oxygen.internalrequest(HTTP.Request("GET", "/api/classes"))
    _ = Biscuit.Server.Oxygen.internalrequest(HTTP.Request("GET", "/api/drive_credentials_status"))
catch
end

# 3. JSON, CSV, YAML serialization
sample_dict = Dict{String, Any}("status" => "ok", "items" => [1, 2, 3], "nested" => Dict("a" => true))
sample_json = JSON.json(sample_dict)
_ = JSON.parse(sample_json)

try
    _ = JSON3.read(sample_json)
catch
end

try
    _ = YAML.load(YAML.dump(sample_dict))
catch
end

# 4. Classes & GoogleDrive path checks
try
    _ = Biscuit.Classes.list_classes()
catch
end

try
    _ = Biscuit.GoogleDrive.google_drive_client_available()
    _ = Biscuit.GoogleDrive.google_drive_token_path()
catch
end

# 5. NameReader preprocessing warmup
try
    dummy_img = fill(UInt8(255), (151, 550))
    _ = Biscuit.NameReader.prepare_name_image(dummy_img)
catch
end


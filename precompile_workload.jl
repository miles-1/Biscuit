# precompile_workload.jl
# Runs typical workloads during compilation to pre-warm method caches and JIT specializations.
# These traces are baked into the PackageCompiler sysimage so the first real launch
# does not recompile route handlers, HTTP listen, or common JSON/CSV paths.

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

# 2. Register routes (compiles handler methods into the sysimage) and warm
#    Oxygen's internal request pipeline without binding a socket.
Biscuit.Server._register_routes!()

try
    _ = Biscuit.Server.Oxygen.internalrequest(HTTP.Request("GET", "/"))
    _ = Biscuit.Server.Oxygen.internalrequest(HTTP.Request("GET", "/api/classes"))
    _ = Biscuit.Server.Oxygen.internalrequest(HTTP.Request("GET", "/api/drive_credentials_status"))
    _ = Biscuit.Server.Oxygen.internalrequest(HTTP.Request("GET", "/api/list_files?dir=."))
catch
end

# 3. Bind a real HTTP server so listen/accept/get paths are compiled too.
#    Use a high port to avoid colliding with a running Biscuit instance.
const _WARMUP_PORT = 18080
try
    Biscuit.serve(host="127.0.0.1", port=_WARMUP_PORT, async=true)
    warmup_url = "http://127.0.0.1:$(_WARMUP_PORT)/"
    for _ in 1:100
        try
            HTTP.get(warmup_url; status_exception=false, retry=false)
            break
        catch
            sleep(0.05)
        end
    end
    try
        HTTP.get(warmup_url; status_exception=false, retry=false)
        HTTP.get("http://127.0.0.1:$(_WARMUP_PORT)/api/classes"; status_exception=false, retry=false)
        HTTP.get("http://127.0.0.1:$(_WARMUP_PORT)/api/drive_credentials_status"; status_exception=false, retry=false)
    catch
    end
catch
finally
    try
        Biscuit.terminate()
    catch
    end
end

# 4. JSON, CSV, YAML serialization
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

# 5. Classes & GoogleDrive path checks
try
    _ = Biscuit.Classes.list_classes()
catch
end

try
    _ = Biscuit.GoogleDrive.google_drive_client_available()
    _ = Biscuit.GoogleDrive.google_drive_token_path()
catch
end

# 6. NameReader preprocessing warmup
try
    dummy_img = fill(UInt8(255), (151, 550))
    _ = Biscuit.NameReader.prepare_name_image(dummy_img)
catch
end

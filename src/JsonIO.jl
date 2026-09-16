module JsonIO

"""
JSON3 wrappers that match the old JSON.jl call shapes and always return mutable
`Dict{String,Any}` / `Vector` trees (JSON3's default objects use Symbol keys).
"""

using JSON3

export json_parse, json_parsefile, json_print, json_string
export _normalize_json_types, _is_json_int, _as_int64_vector

json_parse(text::AbstractString) = _normalize_json_types(JSON3.read(text))
json_parse(bytes::AbstractVector{UInt8}) = _normalize_json_types(JSON3.read(bytes))

function json_parsefile(path::AbstractString)
    return open(path, "r") do io
        _normalize_json_types(JSON3.read(io))
    end
end

json_print(io::IO, obj) = (JSON3.write(io, obj); nothing)
json_print(io::IO, obj, ::Integer) = (JSON3.pretty(io, obj); nothing)

json_string(obj) = JSON3.write(obj)

_is_json_int(v) = (isa(v, Integer) && !(v isa Bool)) ||
    (isa(v, Real) && !(v isa Bool) && isfinite(v) && isinteger(v))

function _as_int64_vector(xs::AbstractVector)
    return Int64[isa(v, Integer) ? Int64(v) : round(Int64, v) for v in xs]
end

function _normalize_json_types(x)
    if isa(x, AbstractDict)
        out = Dict{String, Any}()
        for (k, v) in pairs(x)
            out[String(k)] = _normalize_json_types(v)
        end
        return out
    elseif isa(x, AbstractVector)
        normalized = Any[_normalize_json_types(v) for v in x]
        # Empty JSON arrays are vacuously "all Bool" / "all Int"; leave them untyped
        # rather than turning `[]` into a BitVector.
        isempty(normalized) && return normalized
        if all(v -> isa(v, Bool), normalized)
            return Bool.(normalized)
        elseif all(_is_json_int, normalized)
            return _as_int64_vector(normalized)
        elseif all(v -> isa(v, AbstractFloat), normalized)
            return Float64.(normalized)
        elseif all(v -> isa(v, AbstractString), normalized)
            return String.(normalized)
        else
            return normalized
        end
    end
    return x
end

end # module

module Dmtx

using Libdl

export decode_matrix

function _find_libdmtx()::String
    found = Libdl.find_library(
        ["libdmtx", "dmtx"],
        [
            "/opt/homebrew/lib",
            "/usr/local/lib",
            "/usr/lib",
            "/usr/lib/x86_64-linux-gnu",
            "/usr/lib/aarch64-linux-gnu",
        ],
    )
    isempty(found) && error(
        "libdmtx not found. Install it (macOS: `brew install libdmtx`; " *
        "Debian/Ubuntu: `sudo apt install libdmtx0t64`) and retry."
    )
    return found
end

# Resolved on first decode so `using Biscuit` still works if libdmtx is missing
# until Process Scans needs it.
const _libdmtx_path = Ref{String}()

function libdmtx_path()::String
    isassigned(_libdmtx_path) || (_libdmtx_path[] = _find_libdmtx())
    return _libdmtx_path[]
end

# Explicitly mirror the C struct layout in Julia to handle correct memory offsets
struct DmtxMessage
    arraySize::Csize_t
    codeSize::Csize_t
    outputSize::Csize_t
    outputIdx::Cint
    padCount::Cint
    fnc1::Cint
    array::Ptr{UInt8}
    code::Ptr{UInt8}
    output::Ptr{UInt8}
end

const DMTX_LOCK = ReentrantLock()

function decode_matrix(img_3d::AbstractArray{UInt8, 3})::String
    img_2d = if size(img_3d, 1) == 1
        dropdims(Array(img_3d), dims=1)
    elseif size(img_3d, 3) == 1
        dropdims(Array(img_3d), dims=3)
    else
        error("decode_matrix requires a single-channel image, got size $(size(img_3d))")
    end
    return decode_matrix(img_2d)
end

"""
Decodes a Data Matrix directly from an in-memory 2D Julia Matrix (Grayscale/UInt8).
"""
function decode_matrix(img::Matrix{UInt8})::String
    lock(DMTX_LOCK) do
        # 1. Get matrix dimensions
        height, width = size(img)

        # 2. Instantiate a dmtx image structure
        # DmtxPack8bppK = 300 (Grayscale/8-bit format in libdmtx)
        fmt_grayscale = 300
        dmtx_img = ccall((:dmtxImageCreate, libdmtx_path()), Ptr{Cvoid},
                         (Ptr{UInt8}, Cint, Cint, Cint),
                         img, width, height, fmt_grayscale)
        if dmtx_img == C_NULL
            return ""
        end

        decoder = Ptr{Cvoid}(C_NULL)
        region = Ptr{Cvoid}(C_NULL)
        message = Ptr{Cvoid}(C_NULL)
        decoded_str = ""

        try
            # Set standard image layout expectations (Top-down row order)
            # DmtxPropFlipWindow = 2
            ccall((:dmtxImageSetProp, libdmtx_path()), Cint,
                  (Ptr{Cvoid}, Cint, Cint), dmtx_img, 2, 0)

            # 3. Instantiate the decoder
            decoder = ccall((:dmtxDecodeCreate, libdmtx_path()), Ptr{Cvoid},
                            (Ptr{Cvoid}, Cint), dmtx_img, 1)
            if decoder == C_NULL
                return ""
            end

            # 4. Search and parse the region
            # DmtxTimeoutInfinite = -1
            region = ccall((:dmtxRegionFindNext, libdmtx_path()), Ptr{Cvoid},
                           (Ptr{Cvoid}, Ptr{Cvoid}), decoder, C_NULL)
            if region == C_NULL
                return ""
            end

            message = ccall((:dmtxDecodeMatrixRegion, libdmtx_path()), Ptr{Cvoid},
                            (Ptr{Cvoid}, Ptr{Cvoid}, Cint), decoder, region, -1)
            if message == C_NULL
                return ""
            end

            # Do not use unsafe_string(ptr) here: it calls strlen and can segfault
            # if libdmtx output is not NUL-terminated.
            msg_struct = unsafe_load(convert(Ptr{DmtxMessage}, message))
            if msg_struct.output != C_NULL
                # dmtx.h defines both outputSize (buffer capacity) and outputIdx
                # (bytes written). Prefer outputIdx to avoid scanning raw memory.
                out_cap = Int(msg_struct.outputSize)
                out_idx = Int(msg_struct.outputIdx)
                out_len = if 0 < out_idx <= out_cap
                    out_idx
                elseif out_cap > 0
                    out_cap
                else
                    0
                end
                if out_len > 0
                    out_bytes = unsafe_wrap(Vector{UInt8}, msg_struct.output, out_len; own=false)
                    copied = copy(out_bytes)
                    nul_pos = findfirst(==(0x00), copied)
                    final_len = isnothing(nul_pos) ? length(copied) : (nul_pos - 1)
                    if final_len > 0
                        decoded_str = String(@view copied[1:final_len])
                    end
                end
            end
        finally
            if message != C_NULL
                ccall((:dmtxMessageDestroy, libdmtx_path()), Cvoid, (Ptr{Ptr{Cvoid}},), Ref(message))
            end
            if region != C_NULL
                ccall((:dmtxRegionDestroy, libdmtx_path()), Cvoid, (Ptr{Ptr{Cvoid}},), Ref(region))
            end
            if decoder != C_NULL
                ccall((:dmtxDecodeDestroy, libdmtx_path()), Cvoid, (Ptr{Ptr{Cvoid}},), Ref(decoder))
            end
            ccall((:dmtxImageDestroy, libdmtx_path()), Cvoid, (Ptr{Ptr{Cvoid}},), Ref(dmtx_img))
        end

        return decoded_str
    end
end
end # module

using CodecLz4
using CodecZstd

const COMPRESSION_METHOD_NONE = UInt8(0x00)
const COMPRESSION_METHOD_CHECKSUM_ONLY = UInt8(0x02)
const COMPRESSION_METHOD_LZ4 = UInt8(0x82)
const COMPRESSION_METHOD_ZSTD = UInt8(0x90)

"""
    Compression

Native ClickHouse block compression. `method` is the protocol byte written on
the wire; `level` is a Julia-side encoder setting for methods that support it.
"""
struct Compression
    method::UInt8
    level::Int16

    function Compression(method::Integer, level::Integer = default_compression_level(UInt8(method)))
        method_byte = UInt8(method)
        level_i = Int16(level)
        validate_compression(method_byte, level_i)
        return new(method_byte, level_i)
    end
end

default_compression_level(method::UInt8) =
    method == COMPRESSION_METHOD_ZSTD ? Int16(CodecZstd.DEFAULT_COMPRESSION_LEVEL) : Int16(0)

function validate_compression(method::UInt8, level::Int16)::Nothing
    if method == COMPRESSION_METHOD_NONE || method == COMPRESSION_METHOD_CHECKSUM_ONLY
        level == 0 || throw(ArgumentError("compression method 0x$(string(method, base=16)) does not accept a level"))
    elseif method == COMPRESSION_METHOD_LZ4
        0 <= level <= CodecLz4.LZ4HC_CLEVEL_MAX ||
            throw(ArgumentError("LZ4HC compression level must be between 0 and $(CodecLz4.LZ4HC_CLEVEL_MAX)"))
    elseif method == COMPRESSION_METHOD_ZSTD
        # CodecZstd validates the exact supported range for the linked libzstd.
        level != 0 || throw(ArgumentError("ZSTD compression level must be non-zero"))
    else
        throw(ArgumentError("unsupported ClickHouse compression method byte 0x$(string(method, base=16))"))
    end
    return nothing
end

const COMPRESSION_NONE = Compression(COMPRESSION_METHOD_NONE, 0)
const COMPRESSION_CHECKSUM_ONLY = Compression(COMPRESSION_METHOD_CHECKSUM_ONLY, 0)
const COMPRESSION_LZ4 = Compression(COMPRESSION_METHOD_LZ4, 0)
const COMPRESSION_LZ4HC = Compression(COMPRESSION_METHOD_LZ4, CodecLz4.LZ4HC_CLEVEL_DEFAULT)
const COMPRESSION_ZSTD = Compression(COMPRESSION_METHOD_ZSTD, CodecZstd.DEFAULT_COMPRESSION_LEVEL)

Base.UInt8(mode::Compression) = mode.method

function Base.show(io::IO, mode::Compression)
    if mode == COMPRESSION_NONE
        print(io, "COMPRESSION_NONE")
    elseif mode == COMPRESSION_CHECKSUM_ONLY
        print(io, "COMPRESSION_CHECKSUM_ONLY")
    elseif mode == COMPRESSION_LZ4
        print(io, "COMPRESSION_LZ4")
    elseif mode == COMPRESSION_LZ4HC
        print(io, "COMPRESSION_LZ4HC")
    elseif mode == COMPRESSION_ZSTD
        print(io, "COMPRESSION_ZSTD")
    else
        print(io, "Compression(0x", string(mode.method, base=16), ", ", mode.level, ")")
    end
end

wire_method(mode::Compression)::UInt8 = mode.method

"""compress data according to the compression mode"""
function compress(mode::Compression, data::Vector{UInt8})::Vector{UInt8}
    return if mode.method == COMPRESSION_METHOD_NONE || mode.method == COMPRESSION_METHOD_CHECKSUM_ONLY
        data
    elseif mode.method == COMPRESSION_METHOD_LZ4 && mode.level == 0
        lz4_compress(data)
    elseif mode.method == COMPRESSION_METHOD_LZ4
        lz4_hc_compress(data, mode.level)
    elseif mode.method == COMPRESSION_METHOD_ZSTD
        CodecZstd.transcode(CodecZstd.ZstdCompressor(level = Int(mode.level)), data)
    end
end

function lz4_decompress(
    input::AbstractArray{UInt8},
    expected_size::Integer=length(input) * 2
)::Vector{UInt8}
    expected_size >= 0 ||
        throw(ArgumentError("LZ4 uncompressed size must be non-negative"))
    expected_size <= typemax(Cint) ||
        throw(ArgumentError("LZ4 uncompressed size exceeds codec limit"))
    length(input) <= typemax(Cint) ||
        throw(ArgumentError("LZ4 compressed size exceeds codec limit"))

    # mark the input variable here because it's not used again later and the
    # call to pointer erases the GC's knowledge of the binding
    GC.@preserve input begin
        out_buffer = Vector{UInt8}(undef, expected_size)
        out_size = CodecLz4.LZ4_decompress_safe(
            pointer(input),
            pointer(out_buffer),
            length(input),
            expected_size
        )
        out_size >= 0 ||
            throw(ArgumentError("LZ4 decompression failed"))
        out_size == expected_size ||
            throw(ArgumentError(
                "LZ4 decompressed $(out_size) bytes, expected $(expected_size)",
            ))
        resize!(out_buffer, out_size)
    end
end

"""decompress data according to the compression mode"""
function decompress(
    mode::Compression,
    data::AbstractArray{UInt8},
    uncompressed_size::Integer=length(data) * 2
)::Vector{UInt8}
    return if mode.method == COMPRESSION_METHOD_NONE || mode.method == COMPRESSION_METHOD_CHECKSUM_ONLY
        length(data) == uncompressed_size ||
            throw(ArgumentError(
                "Uncompressed block has $(length(data)) bytes, expected $(uncompressed_size)",
            ))
        data isa Vector{UInt8} ? data : Vector{UInt8}(data)
    elseif mode.method == COMPRESSION_METHOD_LZ4
        GC.@preserve data lz4_decompress(data, uncompressed_size)
    elseif mode.method == COMPRESSION_METHOD_ZSTD
        result = CodecZstd.transcode(
            CodecZstd.ZstdDecompressor,
            data isa Vector{UInt8} ? data : Vector{UInt8}(data),
        )
        length(result) == uncompressed_size ||
            throw(ArgumentError(
                "ZSTD decompressed $(length(result)) bytes, expected $(uncompressed_size)",
            ))
        result
    end
end

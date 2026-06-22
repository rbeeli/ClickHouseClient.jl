@inline function chwrite(sock::ClickHouseSock, x::VarUInt)
    mx::UInt64 = x
    while mx >= 0x80
        chwrite(sock, UInt8(mx & 0xFF) | 0x80)
        mx >>= 7
    end
    chwrite(sock, UInt8(mx & 0xFF))
end

@inline function chread(sock::ClickHouseSock, ::Type{VarUInt})::VarUInt
    x::UInt64 = 0
    s::UInt32 = 0
    i::UInt64 = 0
    while true
        b = chread(sock, UInt8)
        if i == 9 && b >= 0x80
            throw(OverflowError("varint would overflow"))
        end
        if b < 0x80
            if i > 9 || (i == 9 && b > 1)
                throw(OverflowError("varint would overflow"))
            end
            return x | UInt64(b) << s
        end

        x |= UInt64(b & 0x7F) << s
        s += 7
        i += 1
    end
end


@inline function chread(sock::ClickHouseSock, ::Type{T})::T where T <: Number
    ref = Ref{T}()
    GC.@preserve ref begin
        ptr = Base.unsafe_convert(Ptr{T}, ref)
        unsafe_read(sock.io, Ptr{UInt8}(ptr), sizeof(T))
    end
    return ref[]
end

function checked_wire_length(len::UInt64, limit::Integer, what::AbstractString)::Int
    len <= UInt64(limit) ||
        throw(ArgumentError("ClickHouse $(what) length $(len) exceeds configured limit $(limit)"))
    len <= UInt64(typemax(Int)) ||
        throw(ArgumentError("ClickHouse $(what) length $(len) cannot fit in a Julia Int"))
    return Int(len)
end

function checked_vector_length(
    sock::ClickHouseSock,
    count::UInt64,
    ::Type{T},
)::Int where {T}
    len64 = count
    element_size = isbitstype(T) ? sizeof(T) : sizeof(Int)
    limit = sock.settings.max_column_size_bytes
    if element_size > 0 && len64 > UInt64(limit) ÷ UInt64(element_size)
        bytes = len64 * UInt64(element_size)
        throw(ArgumentError(
            "ClickHouse column buffer $(bytes) bytes exceeds configured limit $(limit)",
        ))
    end
    len64 <= UInt64(typemax(Int)) ||
        throw(ArgumentError("ClickHouse column length $(len64) cannot fit in a Julia Int"))
    return Int(len64)
end

checked_vector_length(sock::ClickHouseSock, count::VarUInt, ::Type{T}) where {T} =
    checked_vector_length(sock, UInt64(count), T)

function chread(sock::ClickHouseSock, x::UInt64)::Vector{UInt8}
    len = checked_wire_length(x, sock.settings.max_string_size, "string")
    data = Vector{UInt8}(undef, len)
    GC.@preserve data unsafe_read(sock.io, pointer(data), UInt(len))
    return data
end

function chread(sock::ClickHouseSock, ::Type{String})::String
    len = chread(sock, VarUInt) |> UInt64
    chread(sock, len) |> String
end

@inline function read_clickhouse_uuid(sock::ClickHouseSock)::UUID
    high = UInt128(chread(sock, UInt64))
    low = UInt128(chread(sock, UInt64))
    return UUID((high << 64) | low)
end

# Vector reads
function chread(
    sock::ClickHouseSock,
    ::Type{Vector{T}},
    count::VarUInt,
)::Vector{T} where T <: Number
    len = checked_vector_length(sock, count, T)
    data = Vector{T}(undef, len)
    nbytes = UInt(sizeof(T) * len)
    GC.@preserve data unsafe_read(sock.io, Ptr{UInt8}(pointer(data)), nbytes)
    data
end

chread(
    sock::ClickHouseSock,
    ::Type{Vector{String}},
    count::VarUInt,
)::Vector{String} = [chread(sock, String) for _ ∈ 1:checked_vector_length(sock, count, String)]



# Scalar writes
@inline function chwrite(sock::ClickHouseSock, x::Number)
    ref = Ref(x)
    GC.@preserve ref begin
        ptr = Base.unsafe_convert(Ptr{typeof(x)}, ref)
        unsafe_write(sock.io, Ptr{UInt8}(ptr), sizeof(x))
    end
end

function chwrite(sock::ClickHouseSock, x::AbstractString)
    chwrite(sock, VarUInt(sizeof(x)))
    write(sock.io, codeunits(x))
end

@inline function write_clickhouse_uuid(sock::ClickHouseSock, uuid::UUID)::Nothing
    value = getfield(uuid, :value)
    chwrite(sock, UInt64(value >> 64))
    chwrite(sock, UInt64(value & UInt128(typemax(UInt64))))
    return nothing
end

# Vector writes
chwrite(sock::ClickHouseSock, x::AbstractVector{T}) where T <: Number =
    write(sock.io, x)

chwrite(sock::ClickHouseSock, x::AbstractVector{String}) =
    foreach(x -> chwrite(sock, x), x)


# Compression bytes

function chwrite(sock::ClickHouseSock, compression::Compression)
    chwrite(sock, UInt8(compression))
end

function chread(sock::ClickHouseSock, ::Type{Compression})
    Compression(chread(sock, UInt8))
end

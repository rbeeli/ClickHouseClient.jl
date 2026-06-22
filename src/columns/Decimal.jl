using DecFP

is_ch_type(::Val{:Decimal32}) = true
is_ch_type(::Val{:Decimal64}) = true
is_ch_type(::Val{:Decimal128}) = true
is_ch_type(::Val{:Decimal256}) = true
is_ch_type(::Val{:Decimal}) = true

abstract type AbstractClickHouseDecimal{S} end

"""
    ClickHouseDecimal32{S}(value)

Exact scaled-integer representation for ClickHouse `Decimal32(S)` values.
`S` is the ClickHouse scale and `value` is the stored signed integer.
"""
struct ClickHouseDecimal32{S} <: AbstractClickHouseDecimal{S}
    value::Int32

    function ClickHouseDecimal32{S}(value::Integer) where {S}
        validate_decimal_scale(S, 9)
        new{S}(decimal_raw_value(Int32, value, 9, "Decimal32"))
    end
end

"""
    ClickHouseDecimal64{S}(value)

Exact scaled-integer representation for ClickHouse `Decimal64(S)` values.
`S` is the ClickHouse scale and `value` is the stored signed integer.
"""
struct ClickHouseDecimal64{S} <: AbstractClickHouseDecimal{S}
    value::Int64

    function ClickHouseDecimal64{S}(value::Integer) where {S}
        validate_decimal_scale(S, 18)
        new{S}(decimal_raw_value(Int64, value, 18, "Decimal64"))
    end
end

"""
    ClickHouseDecimal128{S}(value)

Exact scaled-integer representation for ClickHouse `Decimal128(S)` values.
`S` is the ClickHouse scale and `value` is the stored signed integer.
"""
struct ClickHouseDecimal128{S} <: AbstractClickHouseDecimal{S}
    value::Int128

    function ClickHouseDecimal128{S}(value::Integer) where {S}
        validate_decimal_scale(S, 38)
        new{S}(decimal_raw_value(Int128, value, 38, "Decimal128"))
    end
end

"""
    ClickHouseDecimal256{S}(value)

Exact scaled-integer representation for ClickHouse `Decimal256(S)` values.
`S` is the ClickHouse scale and `value` is the stored signed integer.
"""
struct ClickHouseDecimal256{S} <: AbstractClickHouseDecimal{S}
    value::Int256

    function ClickHouseDecimal256{S}(value::Integer) where {S}
        validate_decimal_scale(S, 76)
        new{S}(decimal_raw_value(Int256, value, 76, "Decimal256"))
    end
end

function parse_decimal_precision(precision_str::String)
    precision = parse(Int, precision_str)
    1 <= precision <= 76 ||
        throw(ArgumentError("Decimal precision must be between 1 and 76"))
    return precision
end

function validate_decimal_scale(scale, max_precision::Integer = 76)
    scale isa Integer && 0 <= scale <= max_precision ||
        throw(ArgumentError("Decimal scale must be between 0 and $(max_precision)"))
    return Int(scale)
end

parse_decimal_scale(scale_str::String, max_precision::Integer = 76) =
    validate_decimal_scale(parse(Int, scale_str), max_precision)

function parse_decimal_parameters(precision_str::String, scale_str::String)
    precision = parse_decimal_precision(precision_str)
    scale = parse_decimal_scale(scale_str, precision)
    return precision, scale
end

parse_decimal_parameters(precision_str::String) =
    (parse_decimal_precision(precision_str), 0)

function decimal_raw_value(
    ::Type{IntT},
    value::Integer,
    precision::Integer,
    type_name::AbstractString,
) where {IntT <: Integer}
    raw = IntT(value)
    limit = IntT(10) ^ precision
    -limit < raw < limit ||
        throw(DomainError(
            value,
            "$(type_name) raw scaled integer must be in (-10^$(precision), 10^$(precision))",
        ))
    return raw
end

decimal_scale(::Type{<:AbstractClickHouseDecimal{S}}) where {S} =
    validate_decimal_scale(S)
decimal_scale(x::AbstractClickHouseDecimal) = decimal_scale(typeof(x))

decimal_precision(::Type{<:ClickHouseDecimal32}) = 9
decimal_precision(::Type{<:ClickHouseDecimal64}) = 18
decimal_precision(::Type{<:ClickHouseDecimal128}) = 38
decimal_precision(::Type{<:ClickHouseDecimal256}) = 76
decimal_precision(name::Symbol) =
    name == :Decimal32 ? 9 :
    name == :Decimal64 ? 18 :
    name == :Decimal128 ? 38 :
    name == :Decimal256 ? 76 :
    throw(ArgumentError("Unsupported Decimal type $(name)"))
decimal_precision(x::AbstractClickHouseDecimal) = decimal_precision(typeof(x))

Base.show(io::IO, x::T) where {S, T <: AbstractClickHouseDecimal{S}} =
    print(io, nameof(T), "{$S}(", x.value, ")")

Base.Int32(x::ClickHouseDecimal32) = x.value
Base.Int64(x::ClickHouseDecimal64) = x.value
Base.Int128(x::ClickHouseDecimal128) = x.value
BitIntegers.Int256(x::ClickHouseDecimal256) = x.value

Base.zero(::Type{ClickHouseDecimal32{S}}) where {S} = ClickHouseDecimal32{S}(0)
Base.zero(::Type{ClickHouseDecimal64{S}}) where {S} = ClickHouseDecimal64{S}(0)
Base.zero(::Type{ClickHouseDecimal128{S}}) where {S} = ClickHouseDecimal128{S}(0)
Base.zero(::Type{ClickHouseDecimal256{S}}) where {S} = ClickHouseDecimal256{S}(0)

Base.:(==)(a::T, b::T) where {T <: AbstractClickHouseDecimal} = a.value == b.value
Base.hash(x::T, h::UInt) where {T <: AbstractClickHouseDecimal} =
    hash((T, x.value), h)

result_type(::Val{:Decimal32}, scale_str) =
    Vector{ClickHouseDecimal32{parse_decimal_scale(scale_str, 9)}}
result_type(::Val{:Decimal64}, scale_str) =
    Vector{ClickHouseDecimal64{parse_decimal_scale(scale_str, 18)}}
result_type(::Val{:Decimal128}, scale_str) =
    Vector{ClickHouseDecimal128{parse_decimal_scale(scale_str, 38)}}
result_type(::Val{:Decimal256}, scale_str) =
    Vector{ClickHouseDecimal256{parse_decimal_scale(scale_str, 76)}}

function dec_type_by_precision(precision_str::String)
    precision = parse_decimal_precision(precision_str)

    precision in 1:9 && return :Decimal32
    precision in 10:18 && return :Decimal64
    precision in 19:38 && return :Decimal128
    precision in 39:76 && return :Decimal256
    error("Decimal error: unsupported precision $(precision)")
end

function result_type(::Val{:Decimal}, precision_str, scale_str)
    parse_decimal_parameters(precision_str, scale_str)
    return result_type(
        Val(dec_type_by_precision(precision_str)),
        scale_str,
    )
end

result_type(::Val{:Decimal}, precision_str) =
    result_type(Val(:Decimal), precision_str, "0")

function read_decimal(
    ::Type{DecimalT},
    ::Type{IntT},
    sock::ClickHouseSock,
    num_rows::VarUInt,
    declared_precision::Integer,
    type_name::AbstractString,
) where {DecimalT <: AbstractClickHouseDecimal, IntT <: Integer}
    len = checked_vector_length(sock, num_rows, IntT)
    data = Vector{DecimalT}(undef, len)
    nbytes = UInt(sizeof(IntT) * len)
    GC.@preserve data unsafe_read(sock.io, Ptr{UInt8}(pointer(data)), nbytes)
    for value in data
        decimal_raw_value(IntT, value.value, declared_precision, type_name)
    end
    return data
end

function write_decfp_decimal(
    ::Type{DecT},
    ::Type{IntT},
    sock::ClickHouseSock,
    data,
    scale_str,
    declared_precision::Integer,
    type_name::AbstractString,
) where {DecT, IntT <: Integer}
    scale = parse_decimal_scale(scale_str, declared_precision)
    tmp = Vector{IntT}(undef, length(data))
    for (i, v) in pairs(data)
        (sign, value, exp) = sigexp(convert(DecT, v))

        exp == -scale ||
            throw(ArgumentError(
                "Decimal:Wrong exponent in input data, expected $(scale) got $(exp)"
            ))

        tmp[i] = decimal_raw_value(IntT, sign * value, declared_precision, type_name)
    end
    chwrite(sock, tmp)
end

function write_wrapped_decimal(
    ::Type{DecimalT},
    ::Type{IntT},
    sock::ClickHouseSock,
    data::AbstractVector{<:DecimalT},
    scale_str,
    declared_precision::Integer,
    type_name::AbstractString,
) where {DecimalT <: AbstractClickHouseDecimal, IntT <: Integer}
    scale = parse_decimal_scale(scale_str, declared_precision)
    for (i, v) in pairs(data)
        decimal_scale(v) == scale ||
            throw(ArgumentError("Decimal:Wrong exponent in input data, expected $(scale)"))
        decimal_raw_value(IntT, v.value, declared_precision, type_name)
    end

    if data isa Vector
        nbytes = UInt(sizeof(IntT) * length(data))
        GC.@preserve data unsafe_write(sock.io, Ptr{UInt8}(pointer(data)), nbytes)
        return nothing
    end

    tmp = Vector{IntT}(undef, length(data))
    for (i, v) in pairs(data)
        tmp[i] = decimal_raw_value(IntT, v.value, declared_precision, type_name)
    end
    chwrite(sock, tmp)
end

function write_integer_decimal(
    ::Type{IntT},
    sock::ClickHouseSock,
    data::AbstractVector{<:Integer},
    scale_str,
    declared_precision::Integer,
    type_name::AbstractString,
) where {IntT <: Integer}
    parse_decimal_scale(scale_str, declared_precision)
    tmp = Vector{IntT}(undef, length(data))
    for (i, v) in pairs(data)
        tmp[i] = decimal_raw_value(IntT, v, declared_precision, type_name)
    end
    chwrite(sock, tmp)
end

function read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ::Val{:Decimal32}, scale_str)
    scale = parse_decimal_scale(scale_str, 9)
    return read_decimal(ClickHouseDecimal32{scale}, Int32, sock, num_rows, 9, "Decimal32")
end

function read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ::Val{:Decimal64}, scale_str)
    scale = parse_decimal_scale(scale_str, 18)
    return read_decimal(ClickHouseDecimal64{scale}, Int64, sock, num_rows, 18, "Decimal64")
end

function read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ::Val{:Decimal128}, scale_str)
    scale = parse_decimal_scale(scale_str, 38)
    return read_decimal(ClickHouseDecimal128{scale}, Int128, sock, num_rows, 38, "Decimal128")
end

function read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ::Val{:Decimal256}, scale_str)
    scale = parse_decimal_scale(scale_str, 76)
    return read_decimal(ClickHouseDecimal256{scale}, Int256, sock, num_rows, 76, "Decimal256")
end

function read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ::Val{:Decimal}, precision_str, scale_str)
    declared_precision, scale = parse_decimal_parameters(precision_str, scale_str)
    concrete = dec_type_by_precision(precision_str)
    type_name = "Decimal($(declared_precision),$(scale))"
    if concrete == :Decimal32
        return read_decimal(ClickHouseDecimal32{scale}, Int32, sock, num_rows, declared_precision, type_name)
    elseif concrete == :Decimal64
        return read_decimal(ClickHouseDecimal64{scale}, Int64, sock, num_rows, declared_precision, type_name)
    elseif concrete == :Decimal128
        return read_decimal(ClickHouseDecimal128{scale}, Int128, sock, num_rows, declared_precision, type_name)
    end
    return read_decimal(ClickHouseDecimal256{scale}, Int256, sock, num_rows, declared_precision, type_name)
end

read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ::Val{:Decimal}, precision_str) =
    read_col_data(sock, num_rows, Val(:Decimal), precision_str, "0")

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{<:ClickHouseDecimal32},
    ::Val{:Decimal32},
    scale_str,
)
    return write_wrapped_decimal(ClickHouseDecimal32, Int32, sock, data, scale_str, 9, "Decimal32")
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{<:Integer},
    ::Val{:Decimal32},
    scale_str,
)
    return write_integer_decimal(Int32, sock, data, scale_str, 9, "Decimal32")
end

function write_col_data(sock::ClickHouseSock, data, ::Val{:Decimal32}, scale_str)
    return write_decfp_decimal(Dec32, Int32, sock, data, scale_str, 9, "Decimal32")
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{<:ClickHouseDecimal64},
    ::Val{:Decimal64},
    scale_str,
)
    return write_wrapped_decimal(ClickHouseDecimal64, Int64, sock, data, scale_str, 18, "Decimal64")
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{<:Integer},
    ::Val{:Decimal64},
    scale_str,
)
    return write_integer_decimal(Int64, sock, data, scale_str, 18, "Decimal64")
end

function write_col_data(sock::ClickHouseSock, data, ::Val{:Decimal64}, scale_str)
    return write_decfp_decimal(Dec64, Int64, sock, data, scale_str, 18, "Decimal64")
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{<:ClickHouseDecimal128},
    ::Val{:Decimal128},
    scale_str,
)
    return write_wrapped_decimal(ClickHouseDecimal128, Int128, sock, data, scale_str, 38, "Decimal128")
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{<:Integer},
    ::Val{:Decimal128},
    scale_str,
)
    return write_integer_decimal(Int128, sock, data, scale_str, 38, "Decimal128")
end

function write_col_data(sock::ClickHouseSock, data, ::Val{:Decimal128}, scale_str)
    return write_decfp_decimal(Dec128, Int128, sock, data, scale_str, 38, "Decimal128")
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{<:ClickHouseDecimal256},
    ::Val{:Decimal256},
    scale_str,
)
    return write_wrapped_decimal(ClickHouseDecimal256, Int256, sock, data, scale_str, 76, "Decimal256")
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{<:Integer},
    ::Val{:Decimal256},
    scale_str,
)
    return write_integer_decimal(Int256, sock, data, scale_str, 76, "Decimal256")
end

function write_col_data(sock::ClickHouseSock, data, ::Val{:Decimal}, precision_str, scale_str)
    declared_precision, _ = parse_decimal_parameters(precision_str, scale_str)
    concrete = dec_type_by_precision(precision_str)
    type_name = "Decimal($(declared_precision),$(scale_str))"
    if concrete == :Decimal32
        return if data isa AbstractVector{<:ClickHouseDecimal32}
            write_wrapped_decimal(ClickHouseDecimal32, Int32, sock, data, scale_str, declared_precision, type_name)
        elseif data isa AbstractVector{<:Integer}
            write_integer_decimal(Int32, sock, data, scale_str, declared_precision, type_name)
        else
            write_decfp_decimal(Dec32, Int32, sock, data, scale_str, declared_precision, type_name)
        end
    elseif concrete == :Decimal64
        return if data isa AbstractVector{<:ClickHouseDecimal64}
            write_wrapped_decimal(ClickHouseDecimal64, Int64, sock, data, scale_str, declared_precision, type_name)
        elseif data isa AbstractVector{<:Integer}
            write_integer_decimal(Int64, sock, data, scale_str, declared_precision, type_name)
        else
            write_decfp_decimal(Dec64, Int64, sock, data, scale_str, declared_precision, type_name)
        end
    elseif concrete == :Decimal128
        return if data isa AbstractVector{<:ClickHouseDecimal128}
            write_wrapped_decimal(ClickHouseDecimal128, Int128, sock, data, scale_str, declared_precision, type_name)
        elseif data isa AbstractVector{<:Integer}
            write_integer_decimal(Int128, sock, data, scale_str, declared_precision, type_name)
        else
            write_decfp_decimal(Dec128, Int128, sock, data, scale_str, declared_precision, type_name)
        end
    elseif concrete == :Decimal256
        return if data isa AbstractVector{<:ClickHouseDecimal256}
            write_wrapped_decimal(ClickHouseDecimal256, Int256, sock, data, scale_str, declared_precision, type_name)
        elseif data isa AbstractVector{<:Integer}
            write_integer_decimal(Int256, sock, data, scale_str, declared_precision, type_name)
        else
            throw(ArgumentError("Decimal256 writes require ClickHouseDecimal256 values or raw scaled integers"))
        end
    end

    return write_col_data(
        sock,
        data,
        Val(concrete),
        scale_str,
    )
end

write_col_data(sock::ClickHouseSock, data, ::Val{:Decimal}, precision_str) =
    write_col_data(sock, data, Val(:Decimal), precision_str, "0")

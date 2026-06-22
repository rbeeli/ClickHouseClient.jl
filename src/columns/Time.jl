is_ch_type(::Val{:Time}) = true
is_ch_type(::Val{:Time64}) = true

const TIME64_MAX_PRECISION = 9

struct ClickHouseTime
    seconds::Int32
end

struct ClickHouseTime64{P}
    ticks::Int64

    function ClickHouseTime64{P}(ticks::Integer) where {P}
        validate_time64_precision(P)
        new{P}(Int64(ticks))
    end
end

function validate_time64_precision(precision)
    precision isa Integer ||
        throw(ArgumentError("Time64 precision must be an integer"))
    0 <= precision <= TIME64_MAX_PRECISION ||
        throw(ArgumentError("Time64 precision must be between 0 and 9"))
    return Int(precision)
end

parse_time64_precision(precision_str::String) =
    validate_time64_precision(parse(Int, precision_str))

ClickHouseTime(seconds::Integer) = ClickHouseTime(Int32(seconds))

function ClickHouseTime(t::Time)
    ns = Dates.value(t - Time(0))
    ns % 1_000_000_000 == 0 ||
        throw(ArgumentError("$(t) cannot be represented exactly as Time"))
    seconds = div(ns, 1_000_000_000)
    0 <= seconds <= 86_399 ||
        throw(DomainError(t, "Time values converted from Dates.Time must be within one day"))
    return ClickHouseTime(Int32(seconds))
end

function ClickHouseTime64(t::Time, precision::Integer)
    precision = validate_time64_precision(precision)
    ns = Dates.value(t - Time(0))
    scale = 10^(9 - precision)
    ns % scale == 0 ||
        throw(ArgumentError("$(t) cannot be represented exactly as Time64($(precision))"))
    return ClickHouseTime64{precision}(div(ns, scale))
end

Base.Int32(x::ClickHouseTime) = x.seconds
Base.Int64(x::ClickHouseTime64) = x.ticks
Base.show(io::IO, x::ClickHouseTime) =
    print(io, "ClickHouseTime(", x.seconds, ")")
Base.show(io::IO, x::ClickHouseTime64{P}) where {P} =
    print(io, "ClickHouseTime64{$P}(", x.ticks, ")")

result_type(::Val{:Time}) = Vector{ClickHouseTime}
result_type(::Val{:Time64}, precision_str::String) =
    Vector{ClickHouseTime64{parse_time64_precision(precision_str)}}

function read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ::Val{:Time})
    data = chread(sock, Vector{Int32}, num_rows)
    return ClickHouseTime.(data)
end

function read_col_data(
    sock::ClickHouseSock,
    num_rows::VarUInt,
    ::Val{:Time64},
    precision_str::String,
)
    precision = parse_time64_precision(precision_str)
    data = chread(sock, Vector{Int64}, num_rows)
    T = ClickHouseTime64{precision}
    return T.(data)
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{ClickHouseTime},
    ::Val{:Time},
)
    d = Vector{Int32}(undef, length(data))
    for (i, v) in pairs(data)
        d[i] = v.seconds
    end
    chwrite(sock, d)
end

function write_col_data(sock::ClickHouseSock, data::AbstractVector{Time}, ::Val{:Time})
    write_col_data(sock, ClickHouseTime.(data), Val(:Time))
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{<:ClickHouseTime64},
    ::Val{:Time64},
    precision_str::String,
)
    precision = parse_time64_precision(precision_str)
    d = Vector{Int64}(undef, length(data))
    for (i, v) in pairs(data)
        if v isa ClickHouseTime64{precision}
            d[i] = v.ticks
        else
            error("Cannot write $(typeof(v)) to Time64($(precision)) without precision loss check")
        end
    end
    chwrite(sock, d)
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{Time},
    ::Val{:Time64},
    precision_str::String,
)
    precision = parse_time64_precision(precision_str)
    write_col_data(sock, ClickHouseTime64.(data, precision), Val(:Time64), precision_str)
end

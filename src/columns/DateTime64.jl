is_ch_type(::Val{:DateTime64}) = true

const DATETIME64_MAX_PRECISION = 9
const DATETIME64_EPOCH = DateTime(1970)
const DATETIME64_MIN_DATETIME = DateTime(1900, 1, 1)
const DATETIME64_MAX_EXCLUSIVE_DATETIME = DateTime(2300, 1, 1)

struct DateTime64{P}
    ticks::Int64

    function DateTime64{P}(ticks::Integer) where {P}
        precision = validate_datetime64_precision(P)
        new{P}(validate_datetime64_ticks(ticks, precision))
    end
end

"""
    ClickHouseZonedDateTime64{P}(ticks, timezone)
    ClickHouseZonedDateTime64(datetime64, timezone)

Exact timezone-qualified representation for ClickHouse `DateTime64(P, 'Zone')`
values when `P > 3`. `DateTime64{P}` stores the UTC epoch ticks and `timezone`
stores the ClickHouse timezone metadata.
"""
struct ClickHouseZonedDateTime64{P}
    utc::DateTime64{P}
    timezone::TimeZones.TimeZone

    function ClickHouseZonedDateTime64{P}(
        utc::DateTime64{P},
        timezone::TimeZones.TimeZone,
    ) where {P}
        validate_datetime64_precision(P)
        new{P}(utc, timezone)
    end
end

function validate_datetime64_precision(precision)
    precision isa Integer ||
        throw(ArgumentError("DateTime64 precision must be an integer"))
    0 <= precision <= DATETIME64_MAX_PRECISION ||
        throw(ArgumentError("DateTime64 precision must be between 0 and 9"))
    return Int(precision)
end

parse_datetime64_precision(precision_str::String) =
    validate_datetime64_precision(parse(Int, precision_str))

function DateTime64(ticks::Integer, precision::Integer)
    precision = validate_datetime64_precision(precision)
    return DateTime64{precision}(ticks)
end

function DateTime64(dt::DateTime, precision::Integer = 3)
    precision = validate_datetime64_precision(precision)
    return DateTime64{precision}(datetime64_ticks(dt, precision))
end

ClickHouseZonedDateTime64{P}(
    ticks::Integer,
    timezone::TimeZones.TimeZone,
) where {P} = ClickHouseZonedDateTime64{P}(DateTime64{P}(ticks), timezone)

ClickHouseZonedDateTime64(
    utc::DateTime64{P},
    timezone::TimeZones.TimeZone,
) where {P} = ClickHouseZonedDateTime64{P}(utc, timezone)

Base.Int64(x::DateTime64) = x.ticks
Base.show(io::IO, x::DateTime64{P}) where {P} =
    print(io, "DateTime64{$P}(", x.ticks, ")")
Base.Int64(x::ClickHouseZonedDateTime64) = Int64(x.utc)
Base.show(io::IO, x::ClickHouseZonedDateTime64{P}) where {P} =
    print(io, "ClickHouseZonedDateTime64{$P}(", x.utc.ticks, ", ", x.timezone, ")")

function datetime64_ticks_int128(dt::DateTime, precision::Integer)::Int128
    precision = validate_datetime64_precision(precision)
    millis = Dates.value(dt - DATETIME64_EPOCH)
    if precision >= 3
        return Int128(millis) * Int128(10)^(precision - 3)
    end

    scale = 10^(3 - precision)
    millis % scale == 0 ||
        throw(ArgumentError("$(dt) cannot be represented exactly as DateTime64($(precision))"))
    return Int128(div(millis, scale))
end

function datetime64_tick_bounds(precision::Integer)::Tuple{Int64, Int64}
    precision = validate_datetime64_precision(precision)
    min_ticks = datetime64_ticks_int128(DATETIME64_MIN_DATETIME, precision)
    max_ticks_by_date =
        datetime64_ticks_int128(DATETIME64_MAX_EXCLUSIVE_DATETIME, precision) - 1
    max_ticks = min(max_ticks_by_date, Int128(typemax(Int64)))
    return Int64(min_ticks), Int64(max_ticks)
end

function validate_datetime64_ticks(ticks::Integer, precision::Integer)::Int64
    raw = Int64(ticks)
    min_ticks, max_ticks = datetime64_tick_bounds(precision)
    min_ticks <= raw <= max_ticks ||
        throw(DomainError(
            ticks,
            "DateTime64($(precision)) ticks must be between $(min_ticks) and $(max_ticks)",
        ))
    return raw
end

function datetime64_ticks(dt::DateTime, precision::Integer)::Int64
    ticks = datetime64_ticks_int128(dt, precision)
    typemin(Int64) <= ticks <= typemax(Int64) ||
        throw(DomainError(dt, "DateTime64($(precision)) ticks must fit in Int64"))
    return validate_datetime64_ticks(Int64(ticks), precision)
end

function datetime64_ticks(zdt::TimeZones.ZonedDateTime, precision::Integer)::Int64
    return datetime64_ticks(utc_datetime(zdt), precision)
end

function datetime64_ticks(
    zdt::ClickHouseZonedDateTime64,
    precision::Integer,
)::Int64
    return datetime64_ticks(zdt.utc, precision)
end

function datetime64_ticks(x::DateTime64{P}, precision::Integer)::Int64 where {P}
    precision = validate_datetime64_precision(precision)
    if precision >= P
        return validate_datetime64_ticks(Base.checked_mul(x.ticks, 10^(precision - P)), precision)
    end

    scale = 10^(P - precision)
    x.ticks % scale == 0 ||
        throw(ArgumentError("$(x) cannot be represented exactly as DateTime64($(precision))"))
    return validate_datetime64_ticks(div(x.ticks, scale), precision)
end

function datetime64_to_datetime(x::DateTime64{P}) where {P}
    millis = if P >= 3
        scale = 10^(P - 3)
        x.ticks % scale == 0 ||
            throw(ArgumentError("$(x) cannot be represented exactly as DateTime"))
        div(x.ticks, scale)
    else
        Base.checked_mul(x.ticks, 10^(3 - P))
    end
    return DATETIME64_EPOCH + Millisecond(millis)
end

Dates.DateTime(x::DateTime64) = datetime64_to_datetime(x)
Base.convert(::Type{DateTime}, x::DateTime64) = DateTime(x)

function normalized_datetime64(x::DateTime64{P}) where {P}
    precision = P
    ticks = x.ticks
    while precision > 0 && ticks % 10 == 0
        ticks = div(ticks, 10)
        precision -= 1
    end
    return (ticks, precision)
end

function datetime64_scaled_ticks(x::DateTime64{P}, precision::Integer)::Int128 where {P}
    precision = validate_datetime64_precision(precision)
    if precision < P
        throw(ArgumentError(
            "Cannot scale DateTime64{$P} to lower precision DateTime64{$precision}"
        ))
    end
    return Int128(x.ticks) * Int128(10)^(precision - P)
end

function Base.:(==)(a::DateTime64{P}, b::DateTime64{Q}) where {P, Q}
    return normalized_datetime64(a) == normalized_datetime64(b)
end

function Base.isless(a::DateTime64{P}, b::DateTime64{P}) where {P}
    return a.ticks < b.ticks
end

function Base.isless(a::DateTime64{P}, b::DateTime64{Q}) where {P, Q}
    precision = max(P, Q)
    return datetime64_scaled_ticks(a, precision) < datetime64_scaled_ticks(b, precision)
end

Base.hash(x::DateTime64, h::UInt) = hash((DateTime64, normalized_datetime64(x)), h)

function Base.:(==)(
    a::ClickHouseZonedDateTime64{P},
    b::ClickHouseZonedDateTime64{Q},
) where {P, Q}
    return a.utc == b.utc && a.timezone == b.timezone
end

Base.hash(x::ClickHouseZonedDateTime64, h::UInt) =
    hash((ClickHouseZonedDateTime64, x.utc, x.timezone), h)

result_type(::Val{:DateTime64}, precision_str::String) =
    Vector{DateTime64{parse_datetime64_precision(precision_str)}}
result_type(::Val{:DateTime64}, precision_str::String, ::Nothing) =
    Vector{DateTime64{parse_datetime64_precision(precision_str)}}

function result_type(::Val{:DateTime64}, precision_str::String, timezone::String)
    precision = parse_datetime64_precision(precision_str)
    precision <= 3 && return Vector{TimeZones.ZonedDateTime}
    return Vector{ClickHouseZonedDateTime64{precision}}
end

function read_col_data(
    sock::ClickHouseSock,
    num_rows::VarUInt,
    ::Val{:DateTime64},
    precision_str::String,
    timezone::Union{String, Nothing} = nothing,
)
    precision = parse_datetime64_precision(precision_str)
    data = chread(sock, Vector{Int64}, num_rows)
    T = DateTime64{precision}
    if isnothing(timezone)
        return T.(data)
    end

    tz = parse_clickhouse_timezone(timezone)
    if precision > 3
        Z = ClickHouseZonedDateTime64{precision}
        result = Vector{Z}(undef, length(data))
        for (i, ticks) in pairs(data)
            result[i] = Z(ticks, tz)
        end
        return result
    end

    result = Vector{TimeZones.ZonedDateTime}(undef, length(data))
    for (i, ticks) in pairs(data)
        result[i] = zoned_datetime_from_utc(DateTime(T(ticks)), tz)
    end
    return result
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{<:DateTime64},
    ::Val{:DateTime64},
    precision_str::String,
    timezone::Union{String, Nothing} = nothing,
)
    precision = parse_datetime64_precision(precision_str)
    d = Vector{Int64}(undef, length(data))
    for (i, v) in pairs(data)
        d[i] = datetime64_ticks(v, precision)
    end
    chwrite(sock, d)
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{DateTime},
    ::Val{:DateTime64},
    precision_str::String,
    timezone::Union{String, Nothing} = nothing,
)
    precision = parse_datetime64_precision(precision_str)
    d = Vector{Int64}(undef, length(data))
    for (i, v) in pairs(data)
        d[i] = datetime64_ticks(v, precision)
    end
    chwrite(sock, d)
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{<:TimeZones.ZonedDateTime},
    ::Val{:DateTime64},
    precision_str::String,
    timezone::Union{String, Nothing} = nothing,
)
    precision = parse_datetime64_precision(precision_str)
    d = Vector{Int64}(undef, length(data))
    for (i, v) in pairs(data)
        d[i] = datetime64_ticks(v, precision)
    end
    chwrite(sock, d)
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{<:ClickHouseZonedDateTime64},
    ::Val{:DateTime64},
    precision_str::String,
    timezone::Union{String, Nothing} = nothing,
)
    precision = parse_datetime64_precision(precision_str)
    d = Vector{Int64}(undef, length(data))
    for (i, v) in pairs(data)
        d[i] = datetime64_ticks(v, precision)
    end
    chwrite(sock, d)
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{<:Integer},
    ::Val{:DateTime64},
    precision_str::String,
    timezone::Union{String, Nothing} = nothing,
)
    parse_datetime64_precision(precision_str)
    d = Vector{Int64}(undef, length(data))
    precision = parse_datetime64_precision(precision_str)
    for i in eachindex(data)
        d[i] = validate_datetime64_ticks(data[i], precision)
    end
    chwrite(sock, d)
end

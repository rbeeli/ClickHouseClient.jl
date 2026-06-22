is_ch_type(::Val{:DateTime}) = true

const CLICKHOUSE_TIMEZONE_CLASS_MASK = TimeZones.Class(:ALL)
const CLICKHOUSE_UTC_TIMEZONE =
    TimeZones.TimeZone("UTC", CLICKHOUSE_TIMEZONE_CLASS_MASK)

function unescape_clickhouse_string_literal(text::AbstractString)
    quote_char = first(text)
    last(text) == quote_char ||
        throw(ArgumentError("Unterminated quoted ClickHouse type argument: $(text)"))

    io = IOBuffer()
    escaped = false
    stop = prevind(text, lastindex(text))
    i = nextind(text, firstindex(text))
    while i <= stop
        c = text[i]
        if escaped
            if c == '0'
                write(io, UInt8(0))
            elseif c == 'b'
                print(io, '\b')
            elseif c == 'f'
                print(io, '\f')
            elseif c == 'n'
                print(io, '\n')
            elseif c == 'r'
                print(io, '\r')
            elseif c == 't'
                print(io, '\t')
            else
                print(io, c)
            end
            escaped = false
        elseif c == '\\'
            escaped = true
        else
            print(io, c)
        end
        i = nextind(text, i)
    end
    escaped &&
        throw(ArgumentError("Unterminated escape in ClickHouse type argument: $(text)"))
    return String(take!(io))
end

function clickhouse_type_string_value(arg::AbstractString)
    text = strip(String(arg))
    isempty(text) && return text
    return is_type_quote(first(text)) ? unescape_clickhouse_string_literal(text) : text
end

parse_clickhouse_timezone(::Nothing) = nothing
parse_clickhouse_timezone(timezone::AbstractString) =
    TimeZones.TimeZone(
        clickhouse_type_string_value(timezone),
        CLICKHOUSE_TIMEZONE_CLASS_MASK,
    )

function zoned_datetime_from_utc(dt::DateTime, timezone::TimeZones.TimeZone)
    utc = TimeZones.ZonedDateTime(dt, CLICKHOUSE_UTC_TIMEZONE)
    return TimeZones.astimezone(utc, timezone)
end

function utc_datetime(zdt::TimeZones.ZonedDateTime)::DateTime
    return DateTime(TimeZones.astimezone(zdt, CLICKHOUSE_UTC_TIMEZONE))
end

result_type(::Val{:DateTime}) = Vector{DateTime}
result_type(::Val{:DateTime}, ::Nothing) = Vector{DateTime}
result_type(::Val{:DateTime}, timezone::String) = Vector{TimeZones.ZonedDateTime}

function read_col_data(
    sock::ClickHouseSock,
    num_rows::VarUInt,
    ::Val{:DateTime},
    timezone::Union{String, Nothing} = nothing,
)
    data = chread(sock, Vector{UInt32}, num_rows)
    if isnothing(timezone)
        return unix2datetime.(data)
    end

    tz = parse_clickhouse_timezone(timezone)
    result = Vector{TimeZones.ZonedDateTime}(undef, length(data))
    for (i, seconds) in pairs(data)
        result[i] = zoned_datetime_from_utc(unix2datetime(seconds), tz)
    end
    return result
end

function datetime_seconds(dt::DateTime)::UInt32
    milliseconds = Dates.value(dt - DateTime(1970))
    milliseconds % 1000 == 0 ||
        throw(ArgumentError("$(dt) cannot be represented exactly as DateTime"))
    seconds = div(milliseconds, 1000)
    0 <= seconds <= typemax(UInt32) ||
        throw(DomainError(dt, "DateTime must be between 1970-01-01 and 2106-02-07"))
    return UInt32(seconds)
end

datetime_seconds(zdt::TimeZones.ZonedDateTime)::UInt32 =
    datetime_seconds(utc_datetime(zdt))

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{DateTime},
    ::Val{:DateTime},
    timezone::Union{String, Nothing} = nothing,
)
    d = Vector{UInt32}(undef, length(data))
    for (i, v) in pairs(data)
        d[i] = datetime_seconds(v)
    end
    chwrite(sock, d)
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector{<:TimeZones.ZonedDateTime},
    ::Val{:DateTime},
    timezone::Union{String, Nothing} = nothing,
)
    d = Vector{UInt32}(undef, length(data))
    for (i, v) in pairs(data)
        d[i] = datetime_seconds(v)
    end
    chwrite(sock, d)
end

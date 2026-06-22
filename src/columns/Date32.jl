is_ch_type(::Val{:Date32}) = true
result_type(::Val{:Date32}) = Vector{Date}

const DATE32_MIN = Date(1900, 1, 1)
const DATE32_MAX = Date(2299, 12, 31)
const DATE32_EPOCH = Date(1970)

function validate_date32(date::Date)::Date
    DATE32_MIN <= date <= DATE32_MAX ||
        throw(DomainError(date, "Date32 must be between $(DATE32_MIN) and $(DATE32_MAX)"))
    return date
end

function date32_days(date::Date)::Int32
    validate_date32(date)
    return Int32(Dates.value(date - DATE32_EPOCH))
end

function read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ::Val{:Date32})
    data = chread(sock, Vector{Int32}, num_rows)
    result = Vector{Date}(undef, length(data))
    for i in eachindex(data)
        result[i] = validate_date32(DATE32_EPOCH + Day(data[i]))
    end
    return result
end

function write_col_data(sock::ClickHouseSock, data::AbstractVector{Date}, ::Val{:Date32})
    d = Vector{Int32}(undef, length(data))
    for (i, v) in pairs(data)
        d[i] = date32_days(v)
    end
    chwrite(sock, d)
end

is_ch_type(::Val{:Date})  = true
result_type(::Val{:Date})  = Vector{Date}

function read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ::Val{:Date})
    data = chread(sock, Vector{UInt16}, num_rows)
    return Date(1970) + Day.(data)

end

function write_col_data(sock::ClickHouseSock,
            data::AbstractVector{Date}, ::Val{:Date})
    d = Vector{UInt16}(undef, length(data))
    for (i, v) in pairs(data)
        days = Dates.value(v - Date(1970))
        0 <= days <= typemax(UInt16) ||
            throw(DomainError(v, "Date must be between 1970-01-01 and 2149-06-06"))
        d[i] = UInt16(days)
    end
    chwrite(sock, d)
end

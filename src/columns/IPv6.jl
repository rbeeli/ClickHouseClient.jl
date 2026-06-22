using Sockets: IPv6
is_ch_type(::Val{:IPv6})  = true
result_type(::Val{:IPv6})  = Vector{IPv6}

function read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ::Val{:IPv6})
    tmp = Vector{IPv6}(undef, checked_vector_length(sock, num_rows, IPv6))
    for i in eachindex(tmp)
        high = UInt128(bswap(chread(sock, UInt64)))
        low = UInt128(bswap(chread(sock, UInt64)))
        tmp[i] = IPv6((high << 64) | low)
    end
    return tmp
end

function write_col_data(sock::ClickHouseSock,
                        data::AbstractVector{IPv6}, ::Val{:IPv6})

    for ip in data
        value = getfield(ip, :host)
        chwrite(sock, bswap(UInt64(value >> 64)))
        chwrite(sock, bswap(UInt64(value & UInt128(typemax(UInt64)))))
    end
    return nothing
end

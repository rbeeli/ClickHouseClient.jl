using Sockets: IPv4
is_ch_type(::Val{:IPv4})  = true
result_type(::Val{:IPv4})  = Vector{IPv4}

function read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ::Val{:IPv4})
    tmp = Vector{IPv4}(undef, checked_vector_length(sock, num_rows, IPv4))
    for i in eachindex(tmp)
        tmp[i] = IPv4(chread(sock, UInt32))
    end
    return tmp
end

function write_col_data(sock::ClickHouseSock,
                        data::AbstractVector{IPv4}, ::Val{:IPv4})

    for ip in data
        chwrite(sock, getfield(ip, :host))
    end
    return nothing
end

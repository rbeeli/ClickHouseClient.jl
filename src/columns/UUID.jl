using UUIDs
is_ch_type(::Val{:UUID})  = true
result_type(::Val{:UUID})  = Vector{UUID}

function read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ::Val{:UUID})
    tmp = Vector{UUID}(undef, checked_vector_length(sock, num_rows, UUID))
    for i in eachindex(tmp)
        tmp[i] = read_clickhouse_uuid(sock)
    end
    return tmp
end

function write_col_data(sock::ClickHouseSock,
                        data::AbstractVector{UUID}, ::Val{:UUID})

    for uuid in data
        write_clickhouse_uuid(sock, uuid)
    end
    return nothing
end

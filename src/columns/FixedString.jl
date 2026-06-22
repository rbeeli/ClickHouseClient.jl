is_ch_type(::Val{:FixedString})  = true
result_type(::Val{:FixedString}, len_str::String)  = Vector{String}

function fixed_string_length(sock::ClickHouseSock, len_str::String)::Int
    len64 = try
        parse(UInt64, len_str)
    catch e
        e isa ArgumentError || e isa OverflowError || rethrow(e)
        throw(ArgumentError("invalid FixedString length: $(len_str)"))
    end
    return checked_wire_length(len64, sock.settings.max_string_size, "FixedString value")
end

function checked_fixed_string_column_bytes(sock::ClickHouseSock, rows::Int, len::Int)::Nothing
    limit = sock.settings.max_column_size_bytes
    rows64 = UInt64(rows)
    len64 = UInt64(len)
    if len64 > 0 && rows64 > UInt64(limit) ÷ len64
        throw(ArgumentError(
            "ClickHouse FixedString column exceeds configured limit $(limit)",
        ))
    end
    return nothing
end

function read_col_data(sock::ClickHouseSock, num_rows::VarUInt,
                        ::Val{:FixedString}, len_str::String)
    len = fixed_string_length(sock, len_str)
    nrows = checked_vector_length(sock, num_rows, String)
    checked_fixed_string_column_bytes(sock, nrows, len)
    result = Vector{String}(undef, nrows)
    for i in eachindex(result)
        result[i] = String(chread(sock, UInt64(len)))
    end
    return result
end

function write_fixed_string(io::IO, str::String, len::Integer)
    nbytes = sizeof(str)
    nbytes <= len || error("Too large value \"$str\" for FixedString($len)")
    Base.write(io, codeunits(str))
    for _ in 1:(len - nbytes)
        Base.write(io, UInt8(0))
    end
end

function write_col_data(sock::ClickHouseSock, data::AbstractVector{String},
                         ::Val{:FixedString}, len_str::String)
    len = fixed_string_length(sock, len_str)
    checked_fixed_string_column_bytes(sock, length(data), len)
    for str in data
        write_fixed_string(sock.io, str, len)
    end
end

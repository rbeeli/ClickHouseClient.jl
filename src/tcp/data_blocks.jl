
const BLOCK_INFO_FIELD_STOP = UInt64(0)
const BLOCK_INFO_FIELD_OVERFLOWS = UInt64(1)
const BLOCK_INFO_FIELD_BUCKET_NUM = UInt64(2)
const BLOCK_INFO_FIELD_OUT_OF_ORDER_BUCKETS = UInt64(3)

# UInt32 || UInt32 || UInt8 = (4 + 4 + 1)
const HEADER_SIZE_W_COMPRESSION = UInt32(9)


struct BlockInfo
    is_overflows::Bool
    bucket_num::Int32
    out_of_order_buckets::Vector{Int32}

    BlockInfo() = new(false, -1, Int32[])
    BlockInfo(is_overflows, bucket_num) = new(is_overflows, bucket_num, Int32[])
    BlockInfo(is_overflows, bucket_num, out_of_order_buckets) =
        new(is_overflows, bucket_num, out_of_order_buckets)
end

function chread_binary_vector(sock::ClickHouseSock, ::Type{T})::Vector{T} where {T <: Number}
    count = chread(sock, VarUInt)
    return chread(sock, Vector{T}, count)
end

function chread(sock::ClickHouseSock, ::Type{BlockInfo})::BlockInfo
    is_overflows = false
    bucket_num = -1
    out_of_order_buckets = Int32[]

    while (field_num = UInt64(chread(sock, VarUInt))) != BLOCK_INFO_FIELD_STOP
        if field_num == BLOCK_INFO_FIELD_OVERFLOWS
            is_overflows = chread(sock, Bool)
        elseif field_num == BLOCK_INFO_FIELD_BUCKET_NUM
            bucket_num = chread(sock, Int32)
        elseif field_num == BLOCK_INFO_FIELD_OUT_OF_ORDER_BUCKETS &&
                has_out_of_order_buckets_in_aggregation(sock.server_rev)
            out_of_order_buckets = chread_binary_vector(sock, Int32)
        else
            throw(ArgumentError("Unknown block info field: $(field_num)"))
        end
    end

    BlockInfo(is_overflows, bucket_num, out_of_order_buckets)
end

function chwrite(sock::ClickHouseSock, x::BlockInfo)
    # This mirrors what the C++ client does.
    chwrite(sock, VarUInt(BLOCK_INFO_FIELD_OVERFLOWS))
    chwrite(sock, x.is_overflows)
    chwrite(sock, VarUInt(BLOCK_INFO_FIELD_BUCKET_NUM))
    chwrite(sock, x.bucket_num)
    if has_out_of_order_buckets_in_aggregation(sock.server_rev)
        chwrite(sock, VarUInt(BLOCK_INFO_FIELD_OUT_OF_ORDER_BUCKETS))
        chwrite(sock, VarUInt(length(x.out_of_order_buckets)))
        chwrite(sock, x.out_of_order_buckets)
    end
    chwrite(sock, VarUInt(BLOCK_INFO_FIELD_STOP))
end

"""
    Column(name, type, data)

One ClickHouse column in a native block. `type` is the ClickHouse type string
used on the wire, and `data` is the Julia vector to encode or the vector read
from the server.
"""
struct Column{T <: AbstractVector}
    name::String
    type::String
    data::T
end

Base.:(==)(a::Column, b::Column) =
    a.name == b.name && a.type == b.type && a.data == b.data

# We can't just use chread here because we need the size to be passed
# in from the `Block` decoder that holds the row count.
function read_col(sock::ClickHouseSock, num_rows::VarUInt)::Column
    name = chread(sock, String)
    type_name = chread(sock, String)

    type = parse_typestring(type_name)
    if has_custom_serialization(sock.server_rev)
        has_custom = chread(sock, UInt8)
        has_custom == 0x00 ||
            throw(ArgumentError("Custom serialization for column $(name) is not supported"))
    end
    data = if UInt64(num_rows) == 0
        result_type(type)(undef, 0)
    else
        try
            read_state_prefix(sock, type)
            read_col_data(sock, num_rows, type)
        catch e
            if e isa ArgumentError
                error("Error while reading col $(name) ($(type)): $(e.msg)")
            else
                rethrow(e)
            end
        end
    end
    Column(name, type_name, data)
end

function chwrite(sock::ClickHouseSock, x::Column)
    chwrite(sock, x.name)
    chwrite(sock, x.type)
    has_custom_serialization(sock.server_rev) && chwrite(sock, UInt8(0))
    isempty(x.data) && return nothing

    try
        type = parse_typestring(x.type)
        write_state_prefix(sock, type)
        write_col_data(sock, x.data, type)
    catch e
        if e isa ArgumentError
            error("Error while writing col $(x.name) ($(x.type)): $(e.msg)")
        else
            rethrow(e)
        end
    end
end

"""
    Block

Native ClickHouse data block. Query APIs usually expose blocks as dictionaries,
`QueryBlock`, or `QueryResult`, but `Block` is used directly for lower-level
protocol helpers and external temporary tables.
"""
struct Block
    temp_table::String
    block_info::BlockInfo
    num_columns::VarUInt
    num_rows::VarUInt
    columns::Vector{Column}
end

function scratch_sock(parent::ClickHouseSock, io::I) where {I<:IO}
    sock = ClickHouseSock(io, parent.settings)
    sock.server_name = parent.server_name
    sock.server_rev = parent.server_rev
    sock.server_timezone = parent.server_timezone
    sock.query_compression = parent.query_compression
    return sock
end

function read_block_payload(sock::ClickHouseSock, temp_table::String)::Block
    block_info = chread(sock, BlockInfo)
    num_columns = chread(sock, VarUInt)
    num_rows = chread(sock, VarUInt)
    ncols = checked_vector_length(sock, num_columns, Column)
    columns = Vector{Column}(undef, ncols)
    for i in eachindex(columns)
        columns[i] = read_col(sock, num_rows)
    end
    return Block(temp_table, block_info, num_columns, num_rows, columns)
end

function read_block(sock::ClickHouseSock, compressed::Bool)::Block
    temp_table = chread(sock, String)
    if compressed
        hash = chread(sock, UInt128)
        method = chread(sock, Compression)
        raw_len = chread(sock, UInt32)
        data_len = chread(sock, UInt32)

        raw_len >= HEADER_SIZE_W_COMPRESSION ||
            throw(ArgumentError("Compressed block length $(raw_len) is smaller than header size"))
        raw_len <= sock.settings.max_compressed_block_size ||
            throw(ArgumentError(
                "Compressed block length $(raw_len) exceeds configured limit $(sock.settings.max_compressed_block_size)",
            ))
        data_len <= sock.settings.max_uncompressed_block_size ||
            throw(ArgumentError(
                "Uncompressed block length $(data_len) exceeds configured limit $(sock.settings.max_uncompressed_block_size)",
            ))

        # Form the packet with header and compressed data for checksum validation.
        packet = Vector{UInt8}(undef, Int(raw_len))
        packet[1] = UInt8(method)
        packet[2:5] = reinterpret(UInt8, [raw_len])
        packet[6:9] = reinterpret(UInt8, [data_len])
        compressed = @view packet[HEADER_SIZE_W_COMPRESSION+1:end]
        read!(sock.io, compressed)
        if city_hash_128(packet) != hash
            throw(ChecksumError())
        end
        data = decompress(method, compressed, data_len)
        return read_block_payload(scratch_sock(sock, IOBuffer(data)), temp_table)
    end

    return read_block_payload(sock, temp_table)
end

chread(sock::ClickHouseSock, ::Type{Block})::Block =
    read_block(sock, compression_enabled(sock))

read_uncompressed_block(sock::ClickHouseSock)::Block = read_block(sock, false)

function write_block_payload(sock::ClickHouseSock, x::Block)
    chwrite(sock, x.block_info)
    chwrite(sock, x.num_columns)
    chwrite(sock, x.num_rows)
    for x ∈ x.columns
        chwrite(sock, x)
    end
end

function write_block(sock::ClickHouseSock, x::Block, compressed::Bool)
    if compressed
        block_io = IOBuffer(read = true, write = true)
        write_block_payload(scratch_sock(sock, block_io), x)
    else
        # Temporary table names aren't written in the compression block, so they
        # are only written here if we aren't compressing the block payload.
        chwrite(sock, x.temp_table)
        write_block_payload(sock, x)
        return
    end

    # packet:
    #   checksum(packet-inner)               :: UInt128  (1)
    #   packet-inner:
    #       compression method ∈ Compression :: UInt8    (2)
    #       |C(D)| + |header|                :: UInt32   (3)
    #       |D|                              :: UInt32   (4)
    #       C(D)                             :: UInt8[]  (5)

    data = take!(block_io)
    compression = active_compression(sock)
    compressed = compress(compression, data)
    if length(data) > typemax(UInt32) ||
            length(compressed) > typemax(UInt32)
        throw(DomainError("Block too big"))
    end

    packet_io = IOBuffer(read = true, write = true)
    packet_sock = scratch_sock(sock, packet_io)
    chwrite(packet_sock, compression)  # (2)
    chwrite(packet_sock, UInt32(length(compressed) + HEADER_SIZE_W_COMPRESSION))  # (3)
    chwrite(packet_sock, UInt32(length(data)))  # (4)
    chwrite(packet_sock, compressed)  # (5)

    block_data = take!(packet_io)  # unroll (2:5) for (1)
    hash = city_hash_128(block_data)  # checksum(packet-inner)
    chwrite(sock, x.temp_table)
    chwrite(sock, hash)  # (1)
    chwrite(sock, block_data) # (2:5)
end

chwrite(sock::ClickHouseSock, x::Block) =
    write_block(sock, x, compression_enabled(sock))

write_uncompressed_block(sock::ClickHouseSock, x::Block) =
    write_block(sock, x, false)

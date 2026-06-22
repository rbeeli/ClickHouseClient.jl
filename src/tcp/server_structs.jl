# This is a special case and can't use @ch_struct because we don't
# know the server revision before reading this packet
struct ServerInfo
    server_name::String
    server_major_ver::VarUInt
    server_minor_ver::VarUInt
    server_rev::VarUInt

    # DBMS_MIN_REVISION_WITH_SERVER_TIMEZONE
    server_timezone::String
    # DBMS_MIN_REVISION_WITH_SERVER_DISPLAY_NAME
    server_display_name::String
    # DBMS_MIN_REVISION_WITH_VERSION_PATCH
    server_version_patch::VarUInt
end

negotiated_protocol_revision(rev) = min(UInt64(rev), UInt64(CLIENT_PROTOCOL_REVISION))

function skip_settings_strings_with_flags(sock::ClickHouseSock)::Nothing
    while true
        name = chread(sock, String)
        isempty(name) && return nothing
        chread(sock, VarUInt) # flags
        chread(sock, String) # value
    end
end

function chread(sock::ClickHouseSock, ::Type{ServerInfo})
    server_name = chread(sock, String)
    server_major_ver = chread(sock, VarUInt)
    server_minor_ver = chread(sock, VarUInt)
    server_rev = chread(sock, VarUInt)
    rev = negotiated_protocol_revision(server_rev)
    has_versioned_parallel_replicas_protocol(rev) && chread(sock, VarUInt)
    server_timezone = has_server_timezone(rev) ?
                        chread(sock, String) : "UTC"
    server_display_name = has_server_display_name(rev) ?
                        chread(sock, String) : ""
    server_version_patch = has_version_patch(rev) ?
                        chread(sock, VarUInt) : VarUInt(0)
    if has_chunked_packets(rev)
        chread(sock, String) # server proto send capability
        chread(sock, String) # server proto receive capability
    end
    if has_password_complexity_rules(rev)
        rules_size = UInt64(chread(sock, VarUInt))
        rules_count = checked_vector_length(sock, rules_size, String)
        for _ ∈ 1:rules_count
            chread(sock, String) # pattern
            chread(sock, String) # message
        end
    end
    has_interserver_secret_v2(rev) && chread(sock, UInt64)
    has_server_settings(rev) && skip_settings_strings_with_flags(sock)
    has_query_plan_serialization(rev) && chread(sock, VarUInt)
    has_versioned_cluster_function_protocol(rev) && chread(sock, VarUInt)
    return ServerInfo(
            server_name,
            server_major_ver,
            server_minor_ver,
            server_rev,
            server_timezone,
            server_display_name,
            server_version_patch
            )
end

function chwrite(sock::ClickHouseSock, info::ServerInfo)
    chwrite(sock, info.server_name)
    chwrite(sock, info.server_major_ver)
    chwrite(sock, info.server_minor_ver)
    chwrite(sock, info.server_rev)
    rev = negotiated_protocol_revision(info.server_rev)
    has_versioned_parallel_replicas_protocol(rev) &&
        chwrite(sock, VarUInt(PARALLEL_REPLICAS_PROTOCOL_VERSION))
    has_server_timezone(rev) && chwrite(sock, info.server_timezone)
    has_server_display_name(rev) && chwrite(sock, info.server_display_name)
    has_version_patch(rev) && chwrite(sock, info.server_version_patch)
    if has_chunked_packets(rev)
        chwrite(sock, "notchunked")
        chwrite(sock, "notchunked")
    end
    has_password_complexity_rules(rev) && chwrite(sock, VarUInt(0))
    has_interserver_secret_v2(rev) && chwrite(sock, UInt64(0))
    has_server_settings(rev) && chwrite(sock, "")
    has_query_plan_serialization(rev) &&
        chwrite(sock, VarUInt(QUERY_PLAN_SERIALIZATION_VERSION))
    has_versioned_cluster_function_protocol(rev) &&
        chwrite(sock, VarUInt(CLUSTER_PROCESSING_PROTOCOL_VERSION))
end

@ch_struct struct ServerPong
end

@ch_struct struct ServerProgress
    rows::VarUInt
    bytes::VarUInt
    total_rows::VarUInt

    @has_total_bytes_in_progress total_bytes::VarUInt = VarUInt(0)
    @has_client_write_info written_rows::VarUInt = VarUInt(0)
    @has_client_write_info written_bytes::VarUInt = VarUInt(0)
    @has_server_query_time_in_progress elapsed_ns::VarUInt = VarUInt(0)
end

@ch_struct struct ServerProfileInfo
    rows::VarUInt
    blocks::VarUInt
    bytes::VarUInt
    applied_limit::Bool
    rows_before_limit::VarUInt
    calc_rows_before_limit::Bool
    @has_rows_before_aggregation applied_aggregation::Bool = false
    @has_rows_before_aggregation rows_before_aggregation::VarUInt = VarUInt(0)
end

@ch_struct struct ServerEndOfStream
end

"""
    TableRef(database, table)

Fully qualified table identifier used by `table_status`.
"""
struct TableRef
    database::String
    table::String
end

TableRef(database::AbstractString, table::AbstractString) =
    TableRef(String(database), String(table))

TableRef(table::AbstractString) = TableRef("", String(table))

function chwrite(sock::ClickHouseSock, table::TableRef)
    chwrite(sock, table.database)
    chwrite(sock, table.table)
end

function chread(sock::ClickHouseSock, ::Type{TableRef})::TableRef
    return TableRef(chread(sock, String), chread(sock, String))
end

function chwrite(sock::ClickHouseSock, tables::Vector{TableRef})
    chwrite(sock, VarUInt(length(tables)))
    foreach(table -> chwrite(sock, table), tables)
end

function chread(sock::ClickHouseSock, ::Type{Vector{TableRef}})::Vector{TableRef}
    count = UInt64(chread(sock, VarUInt))
    len = checked_vector_length(sock, count, TableRef)
    return TableRef[chread(sock, TableRef) for _ in 1:len]
end

"""
    TableStatus

Replication and read-only status returned by `table_status`. `absolute_delay`
is reported by ClickHouse for replicated tables.
"""
struct TableStatus
    is_replicated::Bool
    absolute_delay::VarUInt
    is_readonly::Bool
end

TableStatus(; is_replicated::Bool = false, absolute_delay = 0, is_readonly::Bool = false) =
    TableStatus(is_replicated, VarUInt(absolute_delay), is_readonly)

function chwrite(sock::ClickHouseSock, status::TableStatus)
    chwrite(sock, status.is_replicated)
    if status.is_replicated
        chwrite(sock, status.absolute_delay)
        has_table_read_only_check(sock.server_rev) && chwrite(sock, VarUInt(status.is_readonly))
    end
end

function chread(sock::ClickHouseSock, ::Type{TableStatus})::TableStatus
    is_replicated = chread(sock, Bool)
    if !is_replicated
        return TableStatus(false, VarUInt(0), false)
    end
    absolute_delay = chread(sock, VarUInt)
    is_readonly = has_table_read_only_check(sock.server_rev) ?
        Bool(UInt64(chread(sock, VarUInt))) : false
    return TableStatus(is_replicated, absolute_delay, is_readonly)
end

struct ServerTablesStatusResponse
    table_states_by_id::Dict{TableRef, TableStatus}
end

function chwrite(sock::ClickHouseSock, response::ServerTablesStatusResponse)
    chwrite(sock, VarUInt(length(response.table_states_by_id)))
    for (table, status) in response.table_states_by_id
        chwrite(sock, table)
        chwrite(sock, status)
    end
end

function chread(sock::ClickHouseSock, ::Type{ServerTablesStatusResponse})::ServerTablesStatusResponse
    count = UInt64(chread(sock, VarUInt))
    len = checked_vector_length(sock, count, TableRef)
    result = Dict{TableRef, TableStatus}()
    for _ in 1:len
        table = chread(sock, TableRef)
        result[table] = chread(sock, TableStatus)
    end
    return ServerTablesStatusResponse(result)
end

@ch_struct struct ServerTableColumns
    external_table_name::String
    columns::String
    sample_block::Block
end

@ch_struct struct ServerData
    data::Block
end

@ch_struct struct ServerTotals
    data::Block
end

@ch_struct struct ServerExtremes
    data::Block
end

struct ServerLog
    data::Block
end

struct ServerProfileEvents
    data::Block
end

function chread_log_profile_block(sock::ClickHouseSock)::Block
    if has_compressed_logs_profile_events_columns(sock.server_rev)
        return chread(sock, Block)
    else
        return read_uncompressed_block(sock)
    end
end

chread(sock::ClickHouseSock, ::Type{ServerLog}) =
    ServerLog(chread_log_profile_block(sock))

function chwrite(sock::ClickHouseSock, packet::ServerLog)
    if has_compressed_logs_profile_events_columns(sock.server_rev)
        chwrite(sock, packet.data)
    else
        write_uncompressed_block(sock, packet.data)
    end
end

chread(sock::ClickHouseSock, ::Type{ServerProfileEvents}) =
    ServerProfileEvents(chread_log_profile_block(sock))

function chwrite(sock::ClickHouseSock, packet::ServerProfileEvents)
    if has_compressed_logs_profile_events_columns(sock.server_rev)
        chwrite(sock, packet.data)
    else
        write_uncompressed_block(sock, packet.data)
    end
end

struct ServerPartUUIDs
    uuids::Vector{UUID}
end

function chwrite(sock::ClickHouseSock, packet::ServerPartUUIDs)
    chwrite(sock, VarUInt(length(packet.uuids)))
    for uuid in packet.uuids
        write_clickhouse_uuid(sock, uuid)
    end
    return nothing
end

function chread(sock::ClickHouseSock, ::Type{ServerPartUUIDs})::ServerPartUUIDs
    count = checked_vector_length(sock, chread(sock, VarUInt), UUID)
    uuids = Vector{UUID}(undef, count)
    for i in eachindex(uuids)
        uuids[i] = read_clickhouse_uuid(sock)
    end
    return ServerPartUUIDs(uuids)
end

@ch_struct struct ServerReadTaskRequest
end

@ch_struct struct ServerTimezoneUpdate
    timezone::String
end

@ch_struct struct ServerSSHChallenge
    challenge::String
end

struct ServerMergeTreeAllRangesAnnouncement end
struct ServerMergeTreeReadTaskRequest end

function unsupported_packet(name)
    throw(UnsupportedProtocolFeature("$(name) packets are not supported by this client"))
end

chread(::ClickHouseSock, ::Type{ServerMergeTreeAllRangesAnnouncement}) =
    unsupported_packet("MergeTreeAllRangesAnnouncement")

chread(::ClickHouseSock, ::Type{ServerMergeTreeReadTaskRequest}) =
    unsupported_packet("MergeTreeReadTaskRequest")

struct ServerException
    code::UInt32
    name::String
    message::String
    stack_trace::String
    nested::Union{Nothing, ServerException}
end

@ch_struct struct ServerExceptionBase
    code::UInt32
    name::String
    message::String
    stack_trace::String
    has_nested::Bool
end

function chread(sock::ClickHouseSock, ::Type{ServerException})::ServerException
    base = chread(sock, ServerExceptionBase)
    nested = base.has_nested ? chread(sock, ServerException) : nothing
    ServerException(base.code, base.name, base.message, base.stack_trace, nested)
end

function chwrite(sock::ClickHouseSock, x::ServerException)::Nothing
    has_nested = !isnothing(x.nested)
    base = ServerExceptionBase(x.code, x.name, x.message, x.stack_trace, has_nested)
    chwrite(sock, base)
    has_nested && chwrite(sock, x.nested)
    return nothing
end

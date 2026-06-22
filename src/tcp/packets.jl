@enum ClientCodes::UInt64 begin
    CLIENT_HELLO = 0
    CLIENT_QUERY = 1
    CLIENT_DATA = 2
    CLIENT_CANCEL = 3
    CLIENT_PING = 4
    CLIENT_TABLE_STATUS_REQ = 5
    CLIENT_KEEP_ALIVE = 6
    CLIENT_SCALAR = 7
    CLIENT_IGNORED_PART_UUIDS = 8
    CLIENT_READ_TASK_RESPONSE = 9
    CLIENT_MERGE_TREE_READ_TASK_RESPONSE = 10
    CLIENT_SSH_CHALLENGE_REQUEST = 11
    CLIENT_SSH_CHALLENGE_RESPONSE = 12
    CLIENT_QUERY_PLAN = 13
end

@enum ServerCodes::UInt64 begin
    SERVER_HELLO = 0
    SERVER_DATA = 1
    SERVER_EXCEPTION = 2
    SERVER_PROGRESS = 3
    SERVER_PONG = 4
    SERVER_END_OF_STREAM = 5
    SERVER_PROFILE_INFO = 6
    SERVER_TOTALS = 7
    SERVER_EXTREMES = 8
    SERVER_TABLES_STATUS_REPORT = 9
    SERVER_TABLES_LOG = 10
    SERVER_TABLE_COLUMNS = 11
    SERVER_PART_UUIDS = 12
    SERVER_READ_TASK_REQUEST = 13
    SERVER_PROFILE_EVENTS = 14
    SERVER_MERGE_TREE_ALL_RANGES_ANNOUNCEMENT = 15
    SERVER_MERGE_TREE_READ_TASK_REQUEST = 16
    SERVER_TIMEZONE_UPDATE = 17
    SERVER_SSH_CHALLENGE = 18
end




@reg_packet CLIENT_HELLO ClientHello
@reg_packet CLIENT_QUERY ClientQuery
@reg_packet CLIENT_DATA Block
@reg_packet CLIENT_CANCEL ClientCancel
@reg_packet CLIENT_PING ClientPing
@reg_packet CLIENT_TABLE_STATUS_REQ ClientTableStatusRequest
@reg_packet CLIENT_KEEP_ALIVE ClientKeepAlive
@reg_packet CLIENT_SCALAR ClientScalar
@reg_packet CLIENT_IGNORED_PART_UUIDS ClientIgnoredPartUUIDs
@reg_packet CLIENT_READ_TASK_RESPONSE ClientReadTaskResponse
@reg_packet CLIENT_MERGE_TREE_READ_TASK_RESPONSE ClientMergeTreeReadTaskResponse
@reg_packet CLIENT_SSH_CHALLENGE_REQUEST ClientSSHChallengeRequest
@reg_packet CLIENT_SSH_CHALLENGE_RESPONSE ClientSSHChallengeResponse
@reg_packet CLIENT_QUERY_PLAN ClientQueryPlan

@reg_packet SERVER_HELLO ServerInfo
@reg_packet SERVER_DATA ServerData
@reg_packet SERVER_EXCEPTION ServerException
@reg_packet SERVER_PROGRESS ServerProgress
@reg_packet SERVER_PONG ServerPong
@reg_packet SERVER_END_OF_STREAM ServerEndOfStream
@reg_packet SERVER_PROFILE_INFO ServerProfileInfo
@reg_packet SERVER_TOTALS ServerTotals
@reg_packet SERVER_EXTREMES ServerExtremes
@reg_packet SERVER_TABLES_STATUS_REPORT ServerTablesStatusResponse
@reg_packet SERVER_TABLES_LOG ServerLog
@reg_packet SERVER_TABLE_COLUMNS ServerTableColumns
@reg_packet SERVER_PART_UUIDS ServerPartUUIDs
@reg_packet SERVER_READ_TASK_REQUEST ServerReadTaskRequest
@reg_packet SERVER_PROFILE_EVENTS ServerProfileEvents
@reg_packet SERVER_MERGE_TREE_ALL_RANGES_ANNOUNCEMENT ServerMergeTreeAllRangesAnnouncement
@reg_packet SERVER_MERGE_TREE_READ_TASK_REQUEST ServerMergeTreeReadTaskRequest
@reg_packet SERVER_TIMEZONE_UPDATE ServerTimezoneUpdate
@reg_packet SERVER_SSH_CHALLENGE ServerSSHChallenge

function read_packet(sock::ClickHouseSock, ::Type{CodeT}) where {CodeT}
    opcode = CodeT(UInt64(chread(sock, VarUInt)))
    struct_type = packet_struct(Val(opcode))
    return chread(sock, struct_type)
end

read_client_packet(sock::ClickHouseSock) = read_packet(sock, ClientCodes)

function clickhouse_exception(packet::ServerException)::ClickHouseServerException
    nested = isnothing(packet.nested) ? nothing : clickhouse_exception(packet.nested)
    return ClickHouseServerException(
        packet.code,
        packet.name,
        packet.message,
        packet.stack_trace,
        nested,
    )
end

function read_server_packet(sock::ClickHouseSock)
    packet = try
        read_packet(sock, ServerCodes)
    catch e
        e isa UnsupportedProtocolFeature && close(sock)
        rethrow()
    end

    if typeof(packet) == ServerException
        throw(clickhouse_exception(packet))
    end

    packet
end
function write_packet(sock::ClickHouseSock, packet::T; flush::Bool = true) where {T}

    chwrite(sock, VarUInt(packet_code(T)))
    res = chwrite(sock, packet)
    flush && Base.flush(sock)
    return res
end

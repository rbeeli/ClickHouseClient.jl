const SETTINGS_FLAG_IMPORTANT = UInt64(0x01)
const SETTINGS_FLAG_CUSTOM = UInt64(0x02)

"""
    QuerySetting(name, value; important=false, custom=false)

One per-query ClickHouse setting encoded in the native protocol settings list.
Most callers pass settings through `QueryOptions(settings=...)` as a `Dict`,
`NamedTuple`, or pairs; construct `QuerySetting` directly only when you need
the native `important` or `custom` flags.
"""
struct QuerySetting
    name::String
    value::String
    flags::VarUInt
end

QuerySetting(
    name::AbstractString,
    value;
    important::Bool = false,
    custom::Bool = false,
) = QuerySetting(
    String(name),
    string(value),
    VarUInt((important ? SETTINGS_FLAG_IMPORTANT : 0) |
            (custom ? SETTINGS_FLAG_CUSTOM : 0)),
)

struct QuerySettings
    settings::Vector{QuerySetting}
end

QuerySettings() = QuerySettings(QuerySetting[])
QuerySettings(settings::AbstractVector{QuerySetting}) = QuerySettings(collect(settings))

function chwrite(sock::ClickHouseSock, settings::QuerySettings)
    if !isempty(settings.settings) && !has_settings_serialized_as_strings(sock.server_rev)
        throw(UnsupportedProtocolFeature(
            "non-empty query settings require protocol revision $(has_settings_serialized_as_strings_rev())",
        ))
    end

    for setting in settings.settings
        chwrite(sock, setting.name)
        chwrite(sock, setting.flags)
        chwrite(sock, setting.value)
    end
    chwrite(sock, "")
end

function chread(sock::ClickHouseSock, ::Type{QuerySettings})::QuerySettings
    settings = QuerySetting[]
    while true
        name = chread(sock, String)
        isempty(name) && return QuerySettings(settings)

        if !has_settings_serialized_as_strings(sock.server_rev)
            throw(UnsupportedProtocolFeature(
                "reading binary query settings is not supported",
            ))
        end

        flags = chread(sock, VarUInt)
        value = chread(sock, String)
        push!(settings, QuerySetting(name, value, flags))
    end
end

@enum QueryStage::UInt64 begin
    QUERY_STAGE_FETCH_COLUMNS = 0
    QUERY_STAGE_WITH_MERGEABLE_STATE = 1
    QUERY_STAGE_COMPLETE = 2
end

query_stage_value(stage::QueryStage) = VarUInt(UInt64(stage))
query_stage_value(stage::Integer) = VarUInt(stage)

"""
    OpenTelemetryContext(trace_id, span_id; trace_state="", trace_flags=0)

Trace context attached to a native query packet. `trace_id` may be 16 bytes or
a 32-hex-character string, and `span_id` may be 8 bytes, a 16-hex-character
string, or a `UInt64`.
"""
struct OpenTelemetryContext
    trace_id::NTuple{16, UInt8}
    span_id::NTuple{8, UInt8}
    trace_state::String
    trace_flags::UInt8
end

function fixed_bytes(bytes, n::Integer, name::AbstractString)
    length(bytes) == n ||
        throw(ArgumentError("$(name) must contain $(n) bytes"))
    return ntuple(i -> UInt8(bytes[i]), n)
end

function hex_bytes(hex::AbstractString, n::Integer, name::AbstractString)
    clean = replace(String(hex), "-" => "")
    length(clean) == 2n ||
        throw(ArgumentError("$(name) must contain $(2n) hexadecimal characters"))
    bytes = UInt8[parse(UInt8, clean[i:i+1], base = 16) for i in 1:2:length(clean)]
    return fixed_bytes(bytes, n, name)
end

function uint64_bytes(x::UInt64)
    return ntuple(i -> UInt8((x >> (8 * (8 - i))) & 0xff), 8)
end

OpenTelemetryContext(
    trace_id::AbstractVector{UInt8},
    span_id::AbstractVector{UInt8};
    trace_state::AbstractString = "",
    trace_flags::Integer = 0,
) = OpenTelemetryContext(
    fixed_bytes(trace_id, 16, "trace_id"),
    fixed_bytes(span_id, 8, "span_id"),
    String(trace_state),
    UInt8(trace_flags),
)

OpenTelemetryContext(
    trace_id::AbstractString,
    span_id::AbstractString;
    trace_state::AbstractString = "",
    trace_flags::Integer = 0,
) = OpenTelemetryContext(
    hex_bytes(trace_id, 16, "trace_id"),
    hex_bytes(span_id, 8, "span_id"),
    String(trace_state),
    UInt8(trace_flags),
)

OpenTelemetryContext(
    trace_id::UUID,
    span_id::UInt64;
    trace_state::AbstractString = "",
    trace_flags::Integer = 0,
) = OpenTelemetryContext(
    string(trace_id),
    string(span_id, base = 16, pad = 16);
    trace_state = trace_state,
    trace_flags = trace_flags,
)

struct ClientInfo
    query_kind::UInt8
    initial_user::String
    initial_query_id::String
    initial_address_string::String
    initial_query_start_time_microseconds::Int64
    read_interface::UInt8
    os_user::String
    client_hostname::String
    client_name::String
    client_ver_major::VarUInt
    client_ver_minor::VarUInt
    client_rev::VarUInt
    quota_key::String
    distributed_depth::VarUInt
    client_ver_patch::VarUInt
    has_opentelemetry_trace::UInt8
    trace_id::NTuple{16, UInt8}
    span_id::NTuple{8, UInt8}
    trace_state::String
    trace_flags::UInt8
    collaborate_with_initiator::VarUInt
    obsolete_count_participating_replicas::VarUInt
    number_of_current_replica::VarUInt
    script_query_number::VarUInt
    script_line_number::VarUInt
    has_interserver_jwt::UInt8
    interserver_jwt::String
    client_agent::String
end

const EMPTY_TRACE_ID = ntuple(_ -> UInt8(0), 16)
const EMPTY_SPAN_ID = ntuple(_ -> UInt8(0), 8)

function ClientInfo(
    query_kind,
    initial_user,
    initial_query_id,
    initial_address_string,
    initial_query_start_time_microseconds,
    read_interface,
    os_user,
    client_hostname,
    client_name,
    client_ver_major,
    client_ver_minor,
    client_rev,
    quota_key,
    distributed_depth,
    client_ver_patch,
    has_opentelemetry_trace,
    collaborate_with_initiator,
    obsolete_count_participating_replicas,
    number_of_current_replica,
    script_query_number,
    script_line_number,
    has_interserver_jwt,
)
    return ClientInfo(
        UInt8(query_kind),
        String(initial_user),
        String(initial_query_id),
        String(initial_address_string),
        Int64(initial_query_start_time_microseconds),
        UInt8(read_interface),
        String(os_user),
        String(client_hostname),
        String(client_name),
        VarUInt(client_ver_major),
        VarUInt(client_ver_minor),
        VarUInt(client_rev),
        String(quota_key),
        VarUInt(distributed_depth),
        VarUInt(client_ver_patch),
        UInt8(has_opentelemetry_trace),
        EMPTY_TRACE_ID,
        EMPTY_SPAN_ID,
        "",
        UInt8(0),
        VarUInt(collaborate_with_initiator),
        VarUInt(obsolete_count_participating_replicas),
        VarUInt(number_of_current_replica),
        VarUInt(script_query_number),
        VarUInt(script_line_number),
        UInt8(has_interserver_jwt),
        "",
        "",
    )
end

function ClientInfo(;
    query_id::AbstractString = "",
    initial_user::AbstractString = "",
    quota_key::AbstractString = "",
    opentelemetry::Union{Nothing, OpenTelemetryContext} = nothing,
    os_user::AbstractString = get(ENV, "USER", ""),
    client_hostname::AbstractString = try
        Sockets.gethostname()
    catch
        ""
    end,
    client_agent::AbstractString = get(ENV, "CLICKHOUSE_CLIENT_AGENT", ""),
)
    has_trace = isnothing(opentelemetry) ? UInt8(0) : UInt8(1)
    trace_id = isnothing(opentelemetry) ? EMPTY_TRACE_ID : opentelemetry.trace_id
    span_id = isnothing(opentelemetry) ? EMPTY_SPAN_ID : opentelemetry.span_id
    trace_state = isnothing(opentelemetry) ? "" : opentelemetry.trace_state
    trace_flags = isnothing(opentelemetry) ? UInt8(0) : opentelemetry.trace_flags

    return ClientInfo(
        0x01,
        String(initial_user),
        String(query_id),
        "0.0.0.0:0",
        Int64(round(time() * 1_000_000)),
        0x01,
        String(os_user),
        String(client_hostname),
        CLIENT_NAME,
        CLIENT_PROTOCOL_MAJOR,
        CLIENT_PROTOCOL_MINOR,
        CLIENT_PROTOCOL_REVISION,
        String(quota_key),
        0,
        CLIENT_PROTOCOL_PATCH,
        has_trace,
        trace_id,
        span_id,
        trace_state,
        trace_flags,
        0,
        0,
        0,
        0,
        0,
        0,
        "",
        String(client_agent),
    )
end

function read_trace_context(sock::ClickHouseSock)::Tuple{
    NTuple{16, UInt8},
    NTuple{8, UInt8},
    String,
    UInt8,
}
    trace_id = ntuple(_ -> chread(sock, UInt8), 16)
    span_id = ntuple(_ -> chread(sock, UInt8), 8)
    trace_state = chread(sock, String)
    trace_flags = chread(sock, UInt8)
    return trace_id, span_id, trace_state, trace_flags
end

function write_trace_context(sock::ClickHouseSock, info::ClientInfo)::Nothing
    foreach(x -> chwrite(sock, x), info.trace_id)
    foreach(x -> chwrite(sock, x), info.span_id)
    chwrite(sock, info.trace_state)
    chwrite(sock, info.trace_flags)
    return nothing
end

function chread(sock::ClickHouseSock, ::Type{ClientInfo})::ClientInfo
    query_kind = chread(sock, UInt8)
    if query_kind == 0x00
        return ClientInfo(
            0x00, "", "", "0.0.0.0:0", 0, 0x01, "", "", "",
            0, 0, 0, "", 0, 0, 0, 0, 0, 0, 0, 0, 0,
        )
    end

    initial_user = chread(sock, String)
    initial_query_id = chread(sock, String)
    initial_address_string = chread(sock, String)
    initial_query_start_time_microseconds =
        has_initial_query_start_time(sock.server_rev) ? chread(sock, Int64) : Int64(0)
    read_interface = chread(sock, UInt8)

    if read_interface != 0x01
        throw(UnsupportedProtocolFeature(
            "reading non-TCP ClientInfo interfaces is not supported",
        ))
    end

    os_user = chread(sock, String)
    client_hostname = chread(sock, String)
    client_name = chread(sock, String)
    client_ver_major = chread(sock, VarUInt)
    client_ver_minor = chread(sock, VarUInt)
    client_rev = chread(sock, VarUInt)
    quota_key = has_quota_key(sock.server_rev) ? chread(sock, String) : ""
    distributed_depth = has_distributed_depth(sock.server_rev) ?
        chread(sock, VarUInt) : VarUInt(0)
    client_ver_patch = has_version_patch(sock.server_rev) ?
        chread(sock, VarUInt) : VarUInt(0)

    has_opentelemetry_trace = UInt8(0)
    trace_id = EMPTY_TRACE_ID
    span_id = EMPTY_SPAN_ID
    trace_state = ""
    trace_flags = UInt8(0)
    if has_opentelemetry(sock.server_rev)
        has_opentelemetry_trace = chread(sock, UInt8)
        if has_opentelemetry_trace != 0
            trace_id, span_id, trace_state, trace_flags = read_trace_context(sock)
        end
    end

    collaborate_with_initiator = has_parallel_replicas(sock.server_rev) ?
        chread(sock, VarUInt) : VarUInt(0)
    obsolete_count_participating_replicas = has_parallel_replicas(sock.server_rev) ?
        chread(sock, VarUInt) : VarUInt(0)
    number_of_current_replica = has_parallel_replicas(sock.server_rev) ?
        chread(sock, VarUInt) : VarUInt(0)
    script_query_number = has_query_and_line_numbers(sock.server_rev) ?
        chread(sock, VarUInt) : VarUInt(0)
    script_line_number = has_query_and_line_numbers(sock.server_rev) ?
        chread(sock, VarUInt) : VarUInt(0)

    has_interserver_jwt = UInt8(0)
    interserver_jwt = ""
    if has_jwt_in_interserver(sock.server_rev)
        has_interserver_jwt = chread(sock, UInt8)
        has_interserver_jwt != 0 && (interserver_jwt = chread(sock, String))
    end

    client_agent = has_client_agent(sock.server_rev) ? chread(sock, String) : ""

    return ClientInfo(
        query_kind,
        initial_user,
        initial_query_id,
        initial_address_string,
        initial_query_start_time_microseconds,
        read_interface,
        os_user,
        client_hostname,
        client_name,
        client_ver_major,
        client_ver_minor,
        client_rev,
        quota_key,
        distributed_depth,
        client_ver_patch,
        has_opentelemetry_trace,
        trace_id,
        span_id,
        trace_state,
        trace_flags,
        collaborate_with_initiator,
        obsolete_count_participating_replicas,
        number_of_current_replica,
        script_query_number,
        script_line_number,
        has_interserver_jwt,
        interserver_jwt,
        client_agent,
    )
end

function chwrite(sock::ClickHouseSock, info::ClientInfo)::Nothing
    chwrite(sock, info.query_kind)
    info.query_kind == 0x00 && return nothing

    chwrite(sock, info.initial_user)
    chwrite(sock, info.initial_query_id)
    chwrite(sock, info.initial_address_string)
    has_initial_query_start_time(sock.server_rev) &&
        chwrite(sock, info.initial_query_start_time_microseconds)
    chwrite(sock, info.read_interface)

    if info.read_interface != 0x01
        throw(UnsupportedProtocolFeature(
            "writing non-TCP ClientInfo interfaces is not supported",
        ))
    end

    chwrite(sock, info.os_user)
    chwrite(sock, info.client_hostname)
    chwrite(sock, info.client_name)
    chwrite(sock, info.client_ver_major)
    chwrite(sock, info.client_ver_minor)
    chwrite(sock, info.client_rev)
    has_quota_key(sock.server_rev) && chwrite(sock, info.quota_key)
    has_distributed_depth(sock.server_rev) && chwrite(sock, info.distributed_depth)
    has_version_patch(sock.server_rev) && chwrite(sock, info.client_ver_patch)
    if has_opentelemetry(sock.server_rev)
        chwrite(sock, info.has_opentelemetry_trace)
        info.has_opentelemetry_trace != 0 && write_trace_context(sock, info)
    end
    if has_parallel_replicas(sock.server_rev)
        chwrite(sock, info.collaborate_with_initiator)
        chwrite(sock, info.obsolete_count_participating_replicas)
        chwrite(sock, info.number_of_current_replica)
    end
    if has_query_and_line_numbers(sock.server_rev)
        chwrite(sock, info.script_query_number)
        chwrite(sock, info.script_line_number)
    end
    if has_jwt_in_interserver(sock.server_rev)
        chwrite(sock, info.has_interserver_jwt)
        info.has_interserver_jwt != 0 && chwrite(sock, info.interserver_jwt)
    end
    has_client_agent(sock.server_rev) && chwrite(sock, info.client_agent)
    return nothing
end

@ch_struct struct ClientHello
    client_name::String
    client_dbms_ver_major::VarUInt
    client_dbms_ver_minor::VarUInt
    client_dbms_ver_rev::VarUInt
    database::String
    username::String
    password::String
end

@ch_struct struct ClientPing
end

@ch_struct struct ClientCancel
end

@ch_struct struct ClientKeepAlive
end

@ch_struct struct ClientTableStatusRequest
    tables::Vector{TableRef}
end

@ch_struct struct ClientQuery
    query_id::String
    @has_client_info client_info::ClientInfo = ClientInfo()
    settings::QuerySettings
    @has_interserver_external_roles external_roles::String = ""
    @has_interserver_secret interserver_secret::String = ""
    query_stage::VarUInt
    compression::VarUInt
    query::String
    @has_parameters parameters::QuerySettings = QuerySettings()
end

@ch_struct struct ClientScalar
    data::Block
end

struct ClientIgnoredPartUUIDs
    uuids::Vector{UUID}
end

function chwrite(sock::ClickHouseSock, packet::ClientIgnoredPartUUIDs)
    chwrite(sock, VarUInt(length(packet.uuids)))
    for uuid in packet.uuids
        write_clickhouse_uuid(sock, uuid)
    end
    return nothing
end

function chread(sock::ClickHouseSock, ::Type{ClientIgnoredPartUUIDs})::ClientIgnoredPartUUIDs
    count = checked_vector_length(sock, chread(sock, VarUInt), UUID)
    uuids = Vector{UUID}(undef, count)
    for i in eachindex(uuids)
        uuids[i] = read_clickhouse_uuid(sock)
    end
    return ClientIgnoredPartUUIDs(uuids)
end

struct ClientReadTaskResponse end
struct ClientMergeTreeReadTaskResponse end
struct ClientQueryPlan end

function chread(::ClickHouseSock, ::Type{ClientReadTaskResponse})
    throw(UnsupportedProtocolFeature("ReadTaskResponse packets are not supported by this client"))
end

function chwrite(::ClickHouseSock, ::ClientReadTaskResponse)
    throw(UnsupportedProtocolFeature("ReadTaskResponse packets are not supported by this client"))
end

function chread(::ClickHouseSock, ::Type{ClientMergeTreeReadTaskResponse})
    throw(UnsupportedProtocolFeature("MergeTreeReadTaskResponse packets are not supported by this client"))
end

function chwrite(::ClickHouseSock, ::ClientMergeTreeReadTaskResponse)
    throw(UnsupportedProtocolFeature("MergeTreeReadTaskResponse packets are not supported by this client"))
end

function chread(::ClickHouseSock, ::Type{ClientQueryPlan})
    throw(UnsupportedProtocolFeature("QueryPlan packets are not supported by this client"))
end

function chwrite(::ClickHouseSock, ::ClientQueryPlan)
    throw(UnsupportedProtocolFeature("QueryPlan packets are not supported by this client"))
end

@ch_struct struct ClientSSHChallengeRequest
end

@ch_struct struct ClientSSHChallengeResponse
    signature::String
end

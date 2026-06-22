using ClickHouseClient: ClickHouseSock, CHSettings, is_connected,
                is_busy, chwrite, chread, has_temporary_tables, ClientInfo,
                VarUInt, write_packet, read_packet, @using_socket, ClientHello,
                NativeTCP, TLSConfig


@testset "guarded" begin
    sock = ClickHouseSock(PipeBuffer())
    ClickHouseClient.@guarded sock sock.busy = true
    @test sock.busy == true
    @test ClickHouseClient.@guarded(sock, sock.busy) == true
    name = "test test"
    ClickHouseClient.@guarded sock begin
        sock.server_name = name
    end
    @test sock.server_name == "test test"
end

@testset "transport settings" begin
    plain = CHSettings(host = "localhost", username = "default")
    @test plain.transport == NativeTCP()
    @test plain.port == ClickHouseClient.DBMS_DEFAULT_TCP_PORT

    secure = CHSettings(
        host = "localhost",
        username = "default",
        transport = NativeTCP(tls = TLSConfig()),
    )
    @test secure.port == ClickHouseClient.DBMS_DEFAULT_SECURE_TCP_PORT
    @test secure.transport.tls.verify

    custom = CHSettings(
        host = "localhost",
        username = "default",
        transport = NativeTCP(port = 19000),
    )
    @test custom.port == 19000
end

@testset "busy" begin
    sock = ClickHouseSock(PipeBuffer())
    @test typeof(sock).parameters[1] === typeof(sock.io)
    @test !isabstracttype(typeof(sock.io))

    close(sock)

    try
        @using_socket sock begin
            sleep(1)
        end
        @test false
    catch e
        @test e.msg == "ClickHouseSock not connected"
    end

    sock = ClickHouseSock(PipeBuffer())

    a = @async @using_socket sock begin
        sleep(1)
    end
    sleep(0.2)
    @test is_busy(sock)
    try
        @using_socket sock begin
            sleep(1)
        end
        @test false
    catch e
        @test e.msg == "ClickHouseSock is busy"
    end
    wait(a)
    @test !is_busy(sock)

    sock = ClickHouseSock(PipeBuffer())
    @test_throws ClickHouseClient.ClickHouseServerException @using_socket sock begin
        throw(ClickHouseClient.ClickHouseServerException(1, "Exception", "server error"))
    end
    @test !is_connected(sock)
end

@testset "compression codecs" begin
    payload = Vector{UInt8}(repeat("ClickHouse native Julia client ", 20))
    for mode in (
        COMPRESSION_CHECKSUM_ONLY,
        COMPRESSION_LZ4,
        COMPRESSION_LZ4HC,
        COMPRESSION_ZSTD,
    )
        compressed = ClickHouseClient.compress(mode, payload)
        wire_mode = ClickHouseClient.Compression(UInt8(mode))
        @test ClickHouseClient.decompress(wire_mode, compressed, length(payload)) == payload
    end

    @test UInt8(COMPRESSION_LZ4HC) == UInt8(COMPRESSION_LZ4)
    @test COMPRESSION_LZ4HC != COMPRESSION_LZ4
    @test UInt8(COMPRESSION_ZSTD) == 0x90
    @test_throws ArgumentError ClickHouseClient.lz4_decompress(UInt8[0x00], 4)
end

@testset "wire read limits" begin
    settings = CHSettings(host = "", username = "", max_string_size = 3)
    sock = ClickHouseSock(PipeBuffer(), settings)
    chwrite(sock, VarUInt(4))
    write(sock.io, UInt8[0x61, 0x62, 0x63, 0x64])
    @test_throws ArgumentError chread(sock, String)

    settings = CHSettings(host = "", username = "", max_column_size_bytes = 1)
    sock = ClickHouseSock(PipeBuffer(), settings)
    @test_throws ArgumentError chread(sock, Vector{UInt16}, VarUInt(1))

    settings = CHSettings(
        host = "",
        username = "",
        compression = COMPRESSION_LZ4,
        max_compressed_block_size = 8,
    )
    sock = ClickHouseSock(PipeBuffer(), settings)
    chwrite(sock, "")
    chwrite(sock, UInt128(0))
    chwrite(sock, COMPRESSION_LZ4)
    chwrite(sock, UInt32(9))
    chwrite(sock, UInt32(0))
    @test_throws ArgumentError ClickHouseClient.read_block(sock, true)

    settings = CHSettings(host = "", username = "", max_column_size_bytes = 7)
    sock = ClickHouseSock(PipeBuffer(), settings)
    chwrite(sock, "")
    chwrite(sock, VarUInt(0))
    chwrite(sock, VarUInt(1))
    chwrite(sock, VarUInt(0))
    @test_throws ArgumentError ClickHouseClient.read_block(sock, false)
end

@testset "ch structs" begin
    client_info(; quota = "quota", patch = 10) = ClientInfo(
        1,
        "user",
        "aaa-aaa",
        ":0",
        0,
        1,
        "osu",
        "host",
        "name",
        10,
        2,
        23331,
        quota,
        0,
        patch,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    )
    c_info = client_info()

    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, c_info)
    res = chread(sock, ClientInfo)

    @test res == client_info(quota = "", patch = 0)

    sock.server_rev = ClickHouseClient.has_quota_key_rev()
    chwrite(sock, c_info)
    res = chread(sock, ClientInfo)

    @test res == client_info(patch = 0)

    sock.server_rev = ClickHouseClient.has_version_patch_rev()
    chwrite(sock, c_info)
    res = chread(sock, ClientInfo)

    @test res == client_info()
end
@testset "ch packets" begin
    c_hello = ClientHello(
        "ddddd",
        10,
        10,
        10,
        "db",
        "us",
        "pass"
    )

    sock = ClickHouseSock(PipeBuffer())
    write_packet(sock, c_hello)
    res = read_packet(sock, ClickHouseClient.ClientCodes)
    @test res isa ClientHello


    sock = ClickHouseSock(PipeBuffer())
    write_packet(sock, ClickHouseClient.ServerPong())
    res = read_packet(sock, ClickHouseClient.ServerCodes)
    @test res isa ClickHouseClient.ServerPong
end

@testset "server exception diagnostics" begin
    nested = ClickHouseClient.ServerException(
        UInt32(241),
        "DB::Nested",
        "nested message",
        "nested stack",
        nothing,
    )
    packet = ClickHouseClient.ServerException(
        UInt32(60),
        "DB::Exception",
        "outer message",
        "outer stack",
        nested,
    )

    sock = IOBuffer(UInt8[], read = true, write = true, maxsize = 10_000) |>
        ClickHouseSock
    sock.server_rev = ClickHouseClient.CLIENT_PROTOCOL_REVISION
    ClickHouseClient.write_packet(sock, packet)
    seek(sock.io, 0)

    try
        ClickHouseClient.read_server_packet(sock)
        @test false
    catch exc
        @test exc isa ClickHouseServerException
        @test exc.code == 60
        @test exc.stack_trace == "outer stack"
        @test exc.nested isa ClickHouseServerException
        @test exc.nested.code == 241
        @test exc.nested.stack_trace == "nested stack"
        @test occursin("outer stack", sprint(showerror, exc))
        @test occursin("nested stack", sprint(showerror, exc))
    end
end

@testset "query options packets" begin
    sock = IOBuffer(UInt8[], read = true, write = true, maxsize = 10_000) |>
        ClickHouseSock
    sock.server_rev = ClickHouseClient.CLIENT_PROTOCOL_REVISION

    otel = OpenTelemetryContext(
        "00112233-4455-6677-8899-aabbccddeeff",
        "0102030405060708";
        trace_state = "state",
        trace_flags = 1,
    )
    options = QueryOptions(
        query_id = "query-1",
        settings = Dict(:max_threads => 4),
        parameters = Dict("p" => 42),
        quota_key = "quota",
        stage = QUERY_STAGE_FETCH_COLUMNS,
        compression = COMPRESSION_LZ4,
        opentelemetry = otel,
        external_roles = ["role_a"],
    )

    ClickHouseClient.write_query(sock, "SELECT {p:UInt64}"; options = options)
    seek(sock.io, 0)

    packet = read_packet(sock, ClickHouseClient.ClientCodes)
    @test packet isa ClickHouseClient.ClientQuery
    @test packet.query_id == "query-1"
    @test packet.query == "SELECT {p:UInt64}"
    @test UInt64(packet.query_stage) == UInt64(QUERY_STAGE_FETCH_COLUMNS)
    @test UInt64(packet.compression) == 1
    @test packet.client_info.quota_key == "quota"
    @test packet.client_info.has_opentelemetry_trace == 1
    @test packet.client_info.trace_state == "state"
    @test length(packet.settings.settings) == 1
    @test packet.settings.settings[1].name == "max_threads"
    @test packet.settings.settings[1].value == "4"
    @test length(packet.parameters.settings) == 1
    @test packet.parameters.settings[1].name == "p"
    @test UInt64(packet.parameters.settings[1].flags) == ClickHouseClient.SETTINGS_FLAG_CUSTOM
    @test packet.parameters.settings[1].value == "'42'"
    @test packet.external_roles == ClickHouseClient.serialized_string_vector(["role_a"])

    terminator = read_packet(sock, ClickHouseClient.ClientCodes)
    @test terminator isa Block
    @test UInt64(terminator.num_rows) == 0
    @test UInt64(terminator.num_columns) == 0
end

@testset "external table query packets" begin
    sock = IOBuffer(UInt8[], read = true, write = true, maxsize = 10_000) |>
        ClickHouseSock
    sock.server_rev = ClickHouseClient.CLIENT_PROTOCOL_REVISION

    table = ExternalTable(
        "tmp_values",
        ClickHouseClient.Column[
            ClickHouseClient.Column("x", "UInt64", UInt64[1, 2]),
        ],
    )
    ClickHouseClient.write_query(
        sock,
        "SELECT * FROM tmp_values";
        options = QueryOptions(external_tables = [table]),
    )
    seek(sock.io, 0)

    @test read_packet(sock, ClickHouseClient.ClientCodes) isa ClickHouseClient.ClientQuery
    block = read_packet(sock, ClickHouseClient.ClientCodes)
    @test block isa Block
    @test block.temp_table == "tmp_values"
    @test block.columns[1].data == UInt64[1, 2]
    terminator = read_packet(sock, ClickHouseClient.ClientCodes)
    @test terminator isa Block
    @test isempty(terminator.temp_table)
    @test UInt64(terminator.num_rows) == 0
end

@testset "new packet bodies" begin
    sock = IOBuffer(UInt8[], read = true, write = true, maxsize = 10_000) |>
        ClickHouseSock
    sock.server_rev = ClickHouseClient.CLIENT_PROTOCOL_REVISION
    response = ClickHouseClient.ServerTablesStatusResponse(Dict(
        TableRef("db", "tbl") => TableStatus(
            is_replicated = true,
            absolute_delay = 3,
            is_readonly = true,
        ),
    ))
    write_packet(sock, response)
    seek(sock.io, 0)
    decoded = read_packet(sock, ClickHouseClient.ServerCodes)
    status = decoded.table_states_by_id[TableRef("db", "tbl")]
    @test status.is_replicated
    @test UInt64(status.absolute_delay) == 3
    @test status.is_readonly

    sock = IOBuffer(UInt8[], read = true, write = true, maxsize = 10_000) |>
        ClickHouseSock
    sock.server_rev = ClickHouseClient.CLIENT_PROTOCOL_REVISION
    ClickHouseClient.cancel(sock)
    seek(sock.io, 0)
    @test read_packet(sock, ClickHouseClient.ClientCodes) isa ClickHouseClient.ClientCancel

    block = ClickHouseClient.make_block(ClickHouseClient.Column[
        ClickHouseClient.Column("x", "UInt64", UInt64[1]),
    ])

    sock = IOBuffer(UInt8[], read = true, write = true, maxsize = 10_000) |>
        ClickHouseSock
    sock.server_rev = ClickHouseClient.has_compressed_logs_profile_events_columns_rev() - 1
    sock.query_compression = COMPRESSION_LZ4
    write_packet(sock, ClickHouseClient.ServerLog(block))
    seek(sock.io, 0)
    sock.query_compression = COMPRESSION_LZ4
    decoded_log = read_packet(sock, ClickHouseClient.ServerCodes)
    @test decoded_log isa ClickHouseClient.ServerLog
    @test decoded_log.data.columns[1].data == UInt64[1]

    sock = IOBuffer(UInt8[], read = true, write = true, maxsize = 10_000) |>
        ClickHouseSock
    sock.server_rev = ClickHouseClient.has_compressed_logs_profile_events_columns_rev()
    sock.query_compression = COMPRESSION_LZ4
    write_packet(sock, ClickHouseClient.ServerProfileEvents(block))
    seek(sock.io, 0)
    sock.query_compression = COMPRESSION_LZ4
    decoded_events = read_packet(sock, ClickHouseClient.ServerCodes)
    @test decoded_events isa ClickHouseClient.ServerProfileEvents
    @test decoded_events.data.columns[1].data == UInt64[1]

    sock = IOBuffer(UInt8[], read = true, write = true, maxsize = 10_000) |>
        ClickHouseSock
    sock.server_rev = ClickHouseClient.CLIENT_PROTOCOL_REVISION
    chwrite(sock, VarUInt(UInt64(ClickHouseClient.SERVER_MERGE_TREE_READ_TASK_REQUEST)))
    seek(sock.io, 0)
    @test_throws ClickHouseClient.UnsupportedProtocolFeature read_packet(
        sock,
        ClickHouseClient.ServerCodes,
    )
end

using TestItemRunner

@testitem "ClickHouseClient test suite" begin
using Test
using ClickHouseClient
using ClickHouseClient: read_client_packet, read_server_packet
using DataFrames
using Tables
using Dates
using UUIDs
using DecFP
using TimeZones
import JSON3

test_path(parts...) = joinpath(@__DIR__, parts...)
fixture_path(parts...) = joinpath(@__DIR__, "fixtures", parts...)
const FIXTURE_PROTOCOL_REVISION = 54423

function recursive_miss_cmp(a::AbstractVector,b::AbstractVector)
    length(a) != length(b) && return false
    for i in 1:length(a)
        (!recursive_miss_cmp(a[i], b[i])) && return false
    end
    return true
end
function recursive_miss_cmp(a,b)
    return (ismissing(a) && ismissing(b)) ||
        (!ismissing(a == b) && a==b)
end

function mock_server_info()
    return ClickHouseClient.ServerInfo(
        "mock",
        ClickHouseClient.CLIENT_PROTOCOL_MAJOR,
        ClickHouseClient.CLIENT_PROTOCOL_MINOR,
        ClickHouseClient.CLIENT_PROTOCOL_REVISION,
        "UTC",
        "mock server",
        ClickHouseClient.CLIENT_PROTOCOL_PATCH
    )
end

function server_packet_sock(packets...)
    sock = IOBuffer(UInt8[], write = true, read = true, maxsize = 1_000_000) |>
        ClickHouseSock
    sock.server_rev = ClickHouseClient.CLIENT_PROTOCOL_REVISION
    for packet ∈ packets
        ClickHouseClient.write_packet(sock, packet)
    end
    seek(sock.io, 0)
    return sock
end

function server_progress()
    return ClickHouseClient.ServerProgress(
        ClickHouseClient.VarUInt(1),
        ClickHouseClient.VarUInt(2),
        ClickHouseClient.VarUInt(3),
        ClickHouseClient.VarUInt(4),
        ClickHouseClient.VarUInt(5),
        ClickHouseClient.VarUInt(6),
        ClickHouseClient.VarUInt(7),
    )
end

function server_profile_info()
    return ClickHouseClient.ServerProfileInfo(
        ClickHouseClient.VarUInt(1),
        ClickHouseClient.VarUInt(1),
        ClickHouseClient.VarUInt(2),
        false,
        ClickHouseClient.VarUInt(0),
        false,
        false,
        ClickHouseClient.VarUInt(0),
    )
end

function empty_sample_block()
    return ClickHouseClient.make_block(ClickHouseClient.Column[
        ClickHouseClient.Column("x", "UInt64", UInt64[])
    ])
end

include(test_path("defines.jl"))
include(test_path("tcp.jl"))
include(test_path("columns_io.jl"))
include(test_path("cityhash.jl"))
using CategoricalArrays
using Sockets: IPv4, IPv6

function miss_or_equal(a, b)
    return (ismissing(a) && ismissing(b)) ||
            (a==b)
end
@test begin
    sock = IOBuffer([0xC2, 0x0A]) |> ClickHouseSock
    ClickHouseClient.chread(sock, ClickHouseClient.VarUInt) == ClickHouseClient.VarUInt(0x542)
end

@test_throws OverflowError begin
    sock = IOBuffer(fill(UInt8(0x80), 10)) |> ClickHouseSock
    ClickHouseClient.chread(sock, ClickHouseClient.VarUInt)
end

@test begin
    sock = IOBuffer(UInt8[], read=true, write=true, maxsize=10) |>
        ClickHouseSock
    ClickHouseClient.chwrite(sock, ClickHouseClient.VarUInt(100_500))
    seek(sock.io, 0)
    read(sock.io, 3) == [0x94, 0x91, 0x06]
end

@testset "Decode & re-encode client packets (SELECT 1)" begin
    # This .bin file was extracted from a tcpdump captured from a session
    # with the official ClickHouse command line client.
    data = read(open(fixture_path("select1", "client-query.bin")), 100_000, all = true)
    sock = data |> IOBuffer |> ClickHouseSock
    sock.server_rev = FIXTURE_PROTOCOL_REVISION
    packets = []

    # Read packets.

    packet = read_client_packet(sock)
    push!(packets, packet)
    @test typeof(packet) == ClickHouseClient.ClientHello

    packet = read_client_packet(sock)
    push!(packets, packet)
    @test typeof(packet) == ClickHouseClient.ClientPing

    packet = read_client_packet(sock)
    push!(packets, packet)
    @test typeof(packet) == ClickHouseClient.ClientQuery

    packet = read_client_packet(sock)
    push!(packets, packet)
    @test typeof(packet) == ClickHouseClient.Block

    @test eof(sock.io)

    # Re-encode them.

    sock = IOBuffer(UInt8[], write = true, read = true, maxsize = 100_000) |>
        ClickHouseSock
    sock.server_rev = FIXTURE_PROTOCOL_REVISION

    for packet ∈ packets
        ClickHouseClient.write_packet(sock, packet)
    end

    seek(sock.io, 0)
    reencoded_data = read(sock.io, 100_000)

    @test reencoded_data == data
end

@testset "Decode server packets (SELECT 1)" begin
    sock = open(fixture_path("select1", "server-query-resp.bin")) |> ClickHouseSock
    sock.server_rev = FIXTURE_PROTOCOL_REVISION

    packet = read_server_packet(sock)
    @test typeof(packet) == ClickHouseClient.ServerInfo

    packet = read_server_packet(sock)
    @test typeof(packet) == ClickHouseClient.ServerPong

    packet = read_server_packet(sock)
    @test typeof(packet) == ClickHouseClient.ServerData

    packet = read_server_packet(sock)
    @test typeof(packet) == ClickHouseClient.ServerData

    packet = read_server_packet(sock)
    @test typeof(packet) == ClickHouseClient.ServerProfileInfo

    packet = read_server_packet(sock)
    @test typeof(packet) == ClickHouseClient.ServerProgress

    packet = read_server_packet(sock)
    @test typeof(packet) == ClickHouseClient.ServerData

    packet = read_server_packet(sock)
    @test typeof(packet) == ClickHouseClient.ServerEndOfStream

    @test eof(sock.io)
end

@testset "Encode/decode server info" begin
    info = mock_server_info()
    sock = IOBuffer(UInt8[], write = true, read = true, maxsize = 1_000) |>
        ClickHouseSock

    ClickHouseClient.chwrite(sock, info)
    seek(sock.io, 0)
    decoded = ClickHouseClient.chread(sock, ClickHouseClient.ServerInfo)

    @test decoded.server_name == info.server_name
    @test decoded.server_major_ver == info.server_major_ver
    @test decoded.server_minor_ver == info.server_minor_ver
    @test decoded.server_rev == info.server_rev
    @test decoded.server_timezone == info.server_timezone
    @test decoded.server_display_name == info.server_display_name
    @test decoded.server_version_patch == info.server_version_patch
end

@testset "Query protocol helpers" begin
    @test ClickHouseClient.table_identifier("events") == "`events`"
    @test ClickHouseClient.table_identifier("analytics.events") == "`analytics`.`events`"
    @test ClickHouseClient.table_identifier(TableRef("analytics", "weird-table-name")) ==
        "`analytics`.`weird-table-name`"
    @test_throws ArgumentError ClickHouseClient.table_identifier("analytics..events")
    @test_throws ArgumentError ClickHouseClient.table_identifier("unsafe`name")

    valid_columns = Dict(:a => "UInt64")
    @test_throws ArgumentError ClickHouseClient.dict2columns(Dict(:b => UInt64[1]), valid_columns)

    bad_columns = ClickHouseClient.Column[
        ClickHouseClient.Column("a", "UInt64", UInt64[1]),
        ClickHouseClient.Column("b", "UInt64", UInt64[1, 2]),
    ]
    @test_throws DimensionMismatch ClickHouseClient.make_block(bad_columns)

    sock = server_packet_sock(
        server_progress(),
        server_profile_info(),
        ClickHouseClient.ServerEndOfStream(),
    )
    ClickHouseClient.drain_query_response(sock)
    @test eof(sock.io)

    sample_block = empty_sample_block()
    sock = server_packet_sock(server_progress(), ClickHouseClient.ServerData(sample_block))
    decoded_block = ClickHouseClient.read_insert_sample_block(sock)
    @test decoded_block.num_rows == sample_block.num_rows
    @test decoded_block.num_columns == sample_block.num_columns
    @test decoded_block.columns == sample_block.columns
    @test eof(sock.io)

    batch = Dict{Symbol, AbstractVector}()
    valid_column_names = Set([:a, :b])
    column_names = [:a, :b]
    ClickHouseClient.push_record!(
        batch,
        Dict("a" => 1, "b" => missing),
        valid_column_names,
        column_names,
    )
    ClickHouseClient.push_record!(
        batch,
        Dict(:a => 2, :b => 10),
        valid_column_names,
        column_names,
    )
    @test batch[:a] == [1, 2]
    @test recursive_miss_cmp(batch[:b], Union{Missing, Int64}[missing, 10])
    @test_throws ArgumentError ClickHouseClient.push_record!(
        batch,
        Dict(:a => 3),
        valid_column_names,
        column_names,
    )
    ClickHouseClient.push_record!(
        batch,
        Dict(:a => 3, :b => 20, :ignored => 1),
        valid_column_names,
        column_names;
        validate = false,
    )
    @test batch[:a] == [1, 2, 3]
    @test recursive_miss_cmp(batch[:b], Union{Missing, Int64}[missing, 10, 20])

    namedtuple_batch = Dict{Symbol, AbstractVector}()
    ClickHouseClient.push_record!(
        namedtuple_batch,
        (a = 1, b = missing),
        valid_column_names,
        column_names,
    )
    ClickHouseClient.push_record!(
        namedtuple_batch,
        (a = 2, b = 10),
        valid_column_names,
        column_names,
    )
    @test namedtuple_batch[:a] == [1, 2]
    @test recursive_miss_cmp(namedtuple_batch[:b], Union{Missing, Int64}[missing, 10])

    row_batch = Dict{Symbol, AbstractVector}()
    row = first(Tables.rows(DataFrame(:a => [1], :b => [10])))
    ClickHouseClient.push_record!(
        row_batch,
        row,
        valid_column_names,
        column_names,
    )
    @test row_batch[:a] == [1]
    @test row_batch[:b] == [10]

    missing_batch = Dict{Symbol, AbstractVector}(:x => Missing[missing, missing])
    ClickHouseClient.normalize_all_missing_columns!(
        missing_batch,
        Dict(:x => "Nullable(UInt64)"),
    )
    @test recursive_miss_cmp(
        missing_batch[:x],
        Union{UInt64, Missing}[missing, missing],
    )

    complex_sample = ClickHouseClient.Column[
        ClickHouseClient.Column("m", "Map(String, Int64)", Vector{Pair{String, Int64}}[]),
        ClickHouseClient.Column("v", "Variant(Int32, String)", Any[]),
        ClickHouseClient.Column("d", "Dynamic", Any[]),
        ClickHouseClient.Column("j", "JSON", JSON3.Object[]),
    ]
    complex_spec = ClickHouseClient.InsertColumnsSpec(complex_sample)
    complex_batch = ClickHouseClient.make_record_batch(complex_spec)
    ClickHouseClient.push_record!(
        complex_batch,
        Dict(
            :m => Dict("a" => Int64(1)),
            :v => Int32(42),
            :d => true,
            :j => """{"ok":true}""",
        ),
        complex_spec,
    )
    ClickHouseClient.push_record!(
        complex_batch,
        Dict(
            :m => Pair{String, Int64}[],
            :v => missing,
            :d => missing,
            :j => JSON3.read("{}"),
        ),
        complex_spec,
    )
    @test complex_batch[1] == Vector{Pair{String, Int64}}[
        ["a" => Int64(1)],
        Pair{String, Int64}[],
    ]
    @test isequal(complex_batch[2], Union{
        Missing,
        ClickHouseClient.ClickHouseVariant{1, Int32},
        ClickHouseClient.ClickHouseVariant{2, String},
    }[
        ClickHouseClient.ClickHouseVariant{1}(Int32(42)),
        missing,
    ])
    @test isequal(complex_batch[3], Union{
        Missing,
        ClickHouseClient.AbstractClickHouseDynamic,
    }[
        ClickHouseClient.ClickHouseDynamic("Bool", true),
        missing,
    ])
    @test JSON3.write.(complex_batch[4]) == ["""{"ok":true}""", "{}"]

    fast_string_sample = ClickHouseClient.Column[
        ClickHouseClient.Column("name", "String", String[]),
    ]
    fast_string_spec = ClickHouseClient.InsertColumnsSpec(fast_string_sample)
    fast_string_batch = ClickHouseClient.make_record_batch(fast_string_spec)
    ClickHouseClient.push_namedtuple_record_fast_by_name!(
        Tuple(fast_string_batch),
        (name = :alpha,),
        Val((:name,)),
    )
    @test fast_string_batch[1] == ["alpha"]

    result_columns = ClickHouseClient.Column[
        ClickHouseClient.Column("b", "String", ["x", "y"]),
        ClickHouseClient.Column("a", "UInt64", UInt64[1, 2]),
    ]
    result = QueryResult(QuerySchema(result_columns), result_columns, QueryStats())
    @test collect(keys(result)) == [:b, :a]
    @test result[:a] == UInt64[1, 2]
    @test result["b"] == ["x", "y"]
    @test nrows(result) == 2
    @test columnnames(result) == [:b, :a]
    @test columntypes(result) == ["String", "UInt64"]
    @test names(DataFrame(result)) == ["b", "a"]
    @test result_dict(result)[:b] == ["x", "y"]
    @test result.totals === nothing
    @test result.extremes === nothing

    sock = ClickHouseSock(PipeBuffer())
    sock.server_rev = ClickHouseClient.CLIENT_PROTOCOL_REVISION
    sample = ClickHouseClient.make_block(ClickHouseClient.Column[
        ClickHouseClient.Column("x", "UInt64", UInt64[]),
    ])
    data_block = ClickHouseClient.make_block(ClickHouseClient.Column[
        ClickHouseClient.Column("x", "UInt64", UInt64[1, 2]),
    ])
    totals_block = ClickHouseClient.make_block(ClickHouseClient.Column[
        ClickHouseClient.Column("x", "UInt64", UInt64[3]),
    ])
    extremes_block = ClickHouseClient.make_block(ClickHouseClient.Column[
        ClickHouseClient.Column("x", "UInt64", UInt64[0, 9]),
    ])
    ClickHouseClient.write_packet(sock, ClickHouseClient.ServerData(sample))
    ClickHouseClient.write_packet(sock, ClickHouseClient.ServerData(data_block))
    ClickHouseClient.write_packet(sock, ClickHouseClient.ServerTotals(totals_block))
    ClickHouseClient.write_packet(sock, ClickHouseClient.ServerExtremes(extremes_block))
    ClickHouseClient.write_packet(sock, ClickHouseClient.ServerEndOfStream())

    result = query(sock, "SELECT x FROM t WITH TOTALS")
    @test result[:x] == UInt64[1, 2]
    @test result.totals !== nothing
    @test result.totals[:x] == UInt64[3]
    @test result.extremes !== nothing
    @test result.extremes[:x] == UInt64[0, 9]

    sock = ClickHouseSock(PipeBuffer())
    sock.server_rev = ClickHouseClient.CLIENT_PROTOCOL_REVISION
    ClickHouseClient.write_packet(sock, ClickHouseClient.ServerData(sample))
    ClickHouseClient.write_packet(sock, ClickHouseClient.ServerPong())
    @test_throws ErrorException query(sock, "SELECT x FROM t")

    stats = QueryStats()
    sock = ClickHouseSock(PipeBuffer())
    @test ClickHouseClient.handle_query_event(sock, server_progress(); stats = stats)
    @test stats.rows == 1
    @test stats.bytes == 2
    @test stats.elapsed_ns == 7
    @test ClickHouseClient.handle_query_event(sock, server_profile_info(); stats = stats)
    @test stats.profile_info !== nothing

    table_blocks = collect(ClickHouseClient.table_block_iterator(
        DataFrame(:b => ["x", "y", "z"], :a => UInt64[1, 2, 3]),
        2,
    ))
    @test length(table_blocks) == 2
    @test collect(keys(table_blocks[1])) == [:a, :b] ||
        collect(keys(table_blocks[1])) == [:b, :a]
    @test table_blocks[1][:b] == ["x", "y"]
    @test table_blocks[2][:a] == UInt64[3]
end

@testset "Decode client packets (INSERT INTO woof VALUES (1))" begin
    sock = open(fixture_path("insert1", "client.bin")) |> ClickHouseSock
    sock.server_rev = FIXTURE_PROTOCOL_REVISION

    while !eof(sock.io)
        packet = read_client_packet(sock)
    end

    @test true
end

@testset "Decode server packets (OHLC data)" begin
    sock = open(fixture_path("insert-ohlc", "server.bin")) |> ClickHouseSock
    sock.server_rev = FIXTURE_PROTOCOL_REVISION

    while !eof(sock.io)
        packet = read_server_packet(sock)
    end
end

@testset "Decode server packets (enums)" begin
    sock = open(fixture_path("enum", "server.bin")) |> ClickHouseSock
    sock.server_rev = FIXTURE_PROTOCOL_REVISION

    while !eof(sock.io)
        packet = read_server_packet(sock)
    end
end

@testset "Decode & re-encode client packets (enums)" begin
    data = read(open(fixture_path("enum", "client.bin")), 10_000, all = true)
    sock = IOBuffer(data) |> ClickHouseSock
    sock.server_rev = FIXTURE_PROTOCOL_REVISION

    # Read packets.

    packets = []
    while !eof(sock.io)
        packet = read_client_packet(sock)
        push!(packets, packet)
    end

    @test eof(sock.io)

    # Re-encode them.

    sock = IOBuffer(UInt8[], write = true, read = true, maxsize = 10_000) |>
        ClickHouseSock
    sock.server_rev = FIXTURE_PROTOCOL_REVISION
    for packet ∈ packets
        ClickHouseClient.write_packet(sock, packet)
    end

    seek(sock.io, 0)
    reencoded_data = read(sock.io, 10_000)

    @test reencoded_data == data
end

@testset "Decode server packets (exception)" begin
    sock = open(fixture_path("error", "server.bin")) |> ClickHouseSock
    sock.server_rev = FIXTURE_PROTOCOL_REVISION

    while !eof(sock.io)
        try
            packet = read_server_packet(sock)
        catch exc
            if !isa(exc, ClickHouseServerException)
                rethrow()
            end
        end
    end
end

@testset "Decode & re-encode client packets (OHLC data)" begin
    data = read(open(fixture_path("insert-ohlc", "client.bin")), 1_000_000, all = true)
    sock = IOBuffer(data) |> ClickHouseSock
    sock.server_rev = FIXTURE_PROTOCOL_REVISION

    # Read packets.

    packets = []
    while !eof(sock.io)
        packet = read_client_packet(sock)
        push!(packets, packet)
    end

    @test eof(sock.io)

    # Re-encode them.

    sock = IOBuffer(UInt8[], write = true, read = true, maxsize = 1_000_000) |>
        ClickHouseSock
    sock.server_rev = FIXTURE_PROTOCOL_REVISION
    for packet ∈ packets
        ClickHouseClient.write_packet(sock, packet)
    end

    seek(sock.io, 0)
    reencoded_data = read(sock.io, 1_000_000)

    @test reencoded_data == data
end

# Live ClickHouse integration tests live in test/integration/runtests.jl.

end

@run_package_tests

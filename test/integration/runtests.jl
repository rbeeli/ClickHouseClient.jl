using Test
using ClickHouseClient
using DataFrames
using Dates
using UUIDs
using DecFP
using TimeZones
using CategoricalArrays
using Sockets: IPv4, IPv6

include(joinpath(@__DIR__, "support.jl"))
include(joinpath(@__DIR__, "type_roundtrips.jl"))
include(joinpath(@__DIR__, "query_options.jl"))
include(joinpath(@__DIR__, "record_inserts.jl"))
include(joinpath(@__DIR__, "streaming.jl"))

live_tests_enabled() || error(
    "Integration tests require a live ClickHouse server. Run `just start`, then " *
    "`CLICKHOUSECLIENT_TEST_LIVE=1 julia --project=. test/integration/runtests.jl`."
)

function test_live_integration_suite(sock)
    test_type_roundtrips(sock)
    test_query_options(sock)
    test_record_inserts(sock)
    test_streaming_queries(sock)
end

@testset "Queries on localhost DB" begin
    sock = live_connect()
    try
        test_live_integration_suite(sock)
    finally
        close(sock)
    end
end

@testset "Queries on localhost DB + compression (lz4)" begin
    sock = live_connect(compression = COMPRESSION_LZ4)
    try
        test_live_integration_suite(sock)
    finally
        close(sock)
    end
end

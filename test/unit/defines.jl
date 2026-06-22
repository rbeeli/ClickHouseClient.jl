using ClickHouseClient


@testset "server capabilites" begin

    @test ClickHouseClient.has_temporary_tables(50264)
    @test ClickHouseClient.has_temporary_tables(50274)
    @test !ClickHouseClient.has_temporary_tables(50263)
end
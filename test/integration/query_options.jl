function test_query_options(sock)
    @testset "Query options and table status" begin
        table = "ClickHouseJL_QueryOptions"

        execute(sock, "DROP TABLE IF EXISTS $(table)")
        try
            execute(sock, """
                CREATE TABLE $(table) (
                    value UInt64
                )
                ENGINE = Memory
            """)

            param_proj = query(
                sock,
                "SELECT {value:UInt64} AS value";
                options = QueryOptions(parameters = Dict("value" => 42)),
            )
            @test param_proj[:value] == UInt64[42]

            external_proj = query(
                sock,
                "SELECT sum(x) AS total FROM ext_values";
                options = QueryOptions(external_tables = [
                    ExternalTable("ext_values", ClickHouseClient.Column[
                        ClickHouseClient.Column("x", "UInt64", UInt64[1, 2, 3]),
                    ]),
                ]),
            )
            @test external_proj[:total] == UInt64[6]

            status_database = isempty(sock.settings.database) ? "default" : sock.settings.database
            status_ref = TableRef(status_database, table)
            status = table_status(sock, [status_ref])
            @test haskey(status, status_ref)
            @test !status[status_ref].is_replicated

            compressed_proj = query(
                sock,
                "SELECT 7 AS value";
                options = QueryOptions(compression = COMPRESSION_LZ4),
            )
            @test compressed_proj[:value] == Int64[7]
        finally
            cleanup_execute(sock, "DROP TABLE IF EXISTS $(table)")
        end
    end
end

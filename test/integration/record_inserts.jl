function test_record_inserts(sock)
    @testset "Record and Tables.jl inserts" begin
        table = "ClickHouseJL_RecordInserts"

        execute(sock, "DROP TABLE IF EXISTS $(table)")
        try
            execute(sock, """
                CREATE TABLE $(table) (
                    id UInt64,
                    name String,
                    maybe Nullable(Int64),
                    all_missing Nullable(UInt64),
                    ts DateTime64(6)
                )
                ENGINE = Memory
            """)

            record_rows = [
                Dict(
                    :id => UInt64(1),
                    :name => "alpha",
                    :maybe => 10,
                    :all_missing => missing,
                    :ts => DateTime(2026, 1, 1, 0, 0, 0, 100),
                ),
                Dict(
                    "id" => UInt64(2),
                    "name" => "beta",
                    "maybe" => missing,
                    "all_missing" => missing,
                    "ts" => DateTime(2026, 1, 1, 0, 0, 1, 250),
                ),
                Dict(
                    :id => UInt64(3),
                    :name => "gamma",
                    :maybe => 30,
                    :all_missing => missing,
                    :ts => DateTime(2026, 1, 1, 0, 0, 2, 500),
                ),
            ]
            insert_records(sock, table, record_rows; block_size = 2)
            insert_table(sock, table, [
                (
                    id = UInt64(4),
                    name = "delta",
                    maybe = missing,
                    all_missing = missing,
                    ts = DateTime(2026, 1, 1, 0, 0, 3, 750),
                ),
            ]; block_size = 1)

            record_proj = query(sock, "SELECT * FROM $(table) ORDER BY id")
            @test record_proj[:id] == UInt64[1, 2, 3, 4]
            @test record_proj[:name] == ["alpha", "beta", "gamma", "delta"]
            @test recursive_miss_cmp(record_proj[:maybe], [10, missing, 30, missing])
            @test all(ismissing.(record_proj[:all_missing]))
            @test record_proj[:ts] == DateTime64.([
                DateTime(2026, 1, 1, 0, 0, 0, 100),
                DateTime(2026, 1, 1, 0, 0, 1, 250),
                DateTime(2026, 1, 1, 0, 0, 2, 500),
                DateTime(2026, 1, 1, 0, 0, 3, 750),
            ], 6)
        finally
            cleanup_execute(sock, "DROP TABLE IF EXISTS $(table)")
        end
    end
end

function test_type_roundtrips(sock)
    @testset "Type and query result round trips" begin
        table = "ClickHouseJL_TypeRoundTrip"

        execute(sock, "DROP TABLE IF EXISTS $(table)")
        try
            execute(sock, """
                CREATE TABLE $(table) (
                    lul UInt64,
                    oof Float32,
                    foo String,
                    foo_fixed FixedString(5),
                    ddd Date,
                    dt DateTime,
                    dt_tz DateTime('CET'),
                    enu Enum8('a' = 1, 'c' = 3, 'foobar' = 44, 'd' = 9),
                    uuid UUID,
                    nn Nullable(Int64),
                    ns Nullable(String),
                    ne Nullable(Enum16('a' = 1, 'b' = 2)),
                    las LowCardinality(String),
                    lan LowCardinality(Nullable(String)),
                    arrs Array(LowCardinality(String)),
                    arrsn Array(Array(Int64)),
                    arrsnn Array(Array(Nullable(Int64))),
                    safunc SimpleAggregateFunction(sum, Int64),
                    ip4 Nullable(IPv4),
                    ip6 Nullable(IPv6),
                    dt64 DateTime64(6),
                    dt64_1 DateTime64(1),
                    dt64_1tz DateTime64(1, 'GMT'),
                    dt64_9 DateTime64(9),
                    dec32 Decimal32(4),
                    dec Decimal(11,4)
                )
                ENGINE = Memory
            """)

            NullInt = Union{Int64, Missing}
            td = today()
            cet = TimeZone("CET", TimeZones.Class(:ALL))
            gmt = TimeZone("GMT")
            data = Dict(
                :lul => UInt64[42, 1337, 123],
                :oof => Float32[0.0, Base.MathConstants.e, Base.MathConstants.pi],
                :foo => String["aa", "bb", "cc"],
                :foo_fixed => String["aaaaa", "bbb", "cc"],
                :ddd => Date[td, td, td],
                :dt => DateTime[td, td, td],
                :dt_tz => ZonedDateTime.(
                    DateTime[DateTime(td), DateTime(td), DateTime(td)],
                    Ref(cet),
                ),
                :enu => ["a", "c", "foobar"],
                :uuid => [
                    UUID("c187abfa-31c1-4131-a33e-556f23f7aa67"),
                    UUID("f9a7e2b9-dc22-4ca6-b4fe-83ba551ea3bb"),
                    UUID("dc986a81-9f1d-4d96-b618-6e8d034285c1"),
                ],
                :nn => [10, missing, 20],
                :ns => [missing, "sst", "aaa"],
                :ne => CategoricalVector(["a", "b", missing]),
                :las => ["a", "b", "a"],
                :lan => [missing, "b", "a"],
                :arrs => [["a", "b"], ["a"], ["v", "b"]],
                :arrsn => [[[1, 2], [3, 4]], [[5, 6], [7]], [[1], [2]]],
                :arrsnn => [
                    [NullInt[1, 2], NullInt[3, 4]],
                    [NullInt[5, 6], NullInt[7]],
                    [NullInt[1], NullInt[missing]],
                ],
                :safunc => Int64[42, 1337, 123],
                :ip4 => [IPv4("127.0.0.2"), missing, IPv4("127.0.0.1")],
                :ip6 => [
                    IPv6("2a02:aa08:e000:3100::2"),
                    missing,
                    IPv6("2a02:aa08:e000:3100::3"),
                ],
                :dt64 => [
                    DateTime(2020, 2, 2, 10, 5, 10, 320),
                    DateTime(2020, 2, 2, 10, 5, 10, 322),
                    DateTime(2020, 2, 2, 10, 5, 10, 323),
                ],
                :dt64_1 => [
                    DateTime(2020, 2, 2, 10, 5, 10, 300),
                    DateTime(2020, 2, 2, 10, 5, 10, 400),
                    DateTime(2020, 2, 2, 10, 5, 10, 500),
                ],
                :dt64_1tz => ZonedDateTime.(
                    DateTime[
                        DateTime(2020, 2, 2, 10, 5, 11, 300),
                        DateTime(2020, 2, 2, 10, 5, 11, 400),
                        DateTime(2020, 2, 2, 10, 5, 10, 500),
                    ],
                    Ref(gmt),
                ),
                :dt64_9 => DateTime64{9}.([
                    1_580_000_000_123_456_789,
                    1_580_000_001_987_654_321,
                    1_580_000_002_000_000_001,
                ]),
                :dec32 => [
                    Dec32("221.3213"),
                    Dec32("225.3215"),
                    Dec32("227.3219"),
                ],
                :dec => [
                    Dec64("5432221.3213"),
                    Dec64("6432221.4213"),
                    Dec64("7432221.5213"),
                ],
            )

            for _ in 1:3
                insert(sock, table, [data])
            end
            insert(sock, table, repeat([data], 100))

            proj = query(sock, "SELECT * FROM $(table) LIMIT 4")
            @test proj[:lul] == UInt64[42, 1337, 123, 42]
            @test proj[:oof] == Float32[0.0, Base.MathConstants.e, Base.MathConstants.pi, 0.0]
            @test proj[:foo] == String["aa", "bb", "cc", "aa"]
            @test proj[:foo_fixed] == String["aaaaa", "bbb\0\0", "cc\0\0\0", "aaaaa"]
            @test proj[:ddd] == Date[td, td, td, td]
            @test proj[:dt] == DateTime[td, td, td, td]
            @test proj[:dt_tz] == vcat(data[:dt_tz], data[:dt_tz][1:1])
            @test proj[:uuid] == vcat(data[:uuid], data[:uuid][1:1])
            @test recursive_miss_cmp(proj[:nn], [10, missing, 20, 10])
            @test recursive_miss_cmp(proj[:ns], [missing, "sst", "aaa", missing])
            @test recursive_miss_cmp(proj[:ne], ["a", "b", missing, "a"])
            @test proj[:las] == ["a", "b", "a", "a"]
            @test recursive_miss_cmp(proj[:lan], [missing, "b", "a", missing])
            @test proj[:arrs] == [["a", "b"], ["a"], ["v", "b"], ["a", "b"]]
            @test proj[:arrsn] == [
                [[1, 2], [3, 4]],
                [[5, 6], [7]],
                [[1], [2]],
                [[1, 2], [3, 4]],
            ]
            @test recursive_miss_cmp(proj[:arrsnn], [
                [NullInt[1, 2], NullInt[3, 4]],
                [NullInt[5, 6], NullInt[7]],
                [NullInt[1], NullInt[missing]],
                [NullInt[1, 2], NullInt[3, 4]],
            ])
            @test recursive_miss_cmp(proj[:ip4], [
                IPv4("127.0.0.2"),
                missing,
                IPv4("127.0.0.1"),
                IPv4("127.0.0.2"),
            ])
            @test recursive_miss_cmp(proj[:ip6], [
                IPv6("2a02:aa08:e000:3100::2"),
                missing,
                IPv6("2a02:aa08:e000:3100::3"),
                IPv6("2a02:aa08:e000:3100::2"),
            ])
            @test proj[:dt64] == DateTime64.(vcat(data[:dt64], data[:dt64][1:1]), 6)
            @test proj[:dt64_1] == DateTime64.(vcat(data[:dt64_1], data[:dt64_1][1:1]), 1)
            @test proj[:dt64_1tz] == vcat(data[:dt64_1tz], data[:dt64_1tz][1:1])
            @test proj[:dt64_9] == vcat(data[:dt64_9], data[:dt64_9][1:1])
            @test proj[:dec32] == [
                ClickHouseDecimal32{4}(2_213_213),
                ClickHouseDecimal32{4}(2_253_215),
                ClickHouseDecimal32{4}(2_273_219),
                ClickHouseDecimal32{4}(2_213_213),
            ]
            @test proj[:dec] == [
                ClickHouseDecimal64{4}(54_322_213_213),
                ClickHouseDecimal64{4}(64_322_214_213),
                ClickHouseDecimal64{4}(74_322_215_213),
                ClickHouseDecimal64{4}(54_322_213_213),
            ]

            exact_decimals = query(sock, """
                SELECT
                    toDecimal32('999999999', 0) AS dec32,
                    toDecimal64('999999999999999999', 0) AS dec64,
                    toDecimal128('99999999999999999999999999999999999999', 0) AS dec128
            """)
            @test exact_decimals[:dec32] == [ClickHouseDecimal32{0}(999_999_999)]
            @test exact_decimals[:dec64] == [ClickHouseDecimal64{0}(999_999_999_999_999_999)]
            @test exact_decimals[:dec128] == [
                ClickHouseDecimal128{0}(parse(Int128, "99999999999999999999999999999999999999")),
            ]

            timezone_projection = query(sock, """
                SELECT
                    toDateTime('2020-01-01 00:00:00', 'Europe/Zurich') AS dt,
                    toDateTime64('2020-01-01 00:00:00.123', 3, 'Europe/Zurich') AS dt64_ms,
                    toDateTime64('2020-01-01 00:00:00.123456', 6, 'Europe/Zurich') AS dt64_us
            """)
            zurich = TimeZone("Europe/Zurich")
            @test timezone_projection[:dt] == [ZonedDateTime(DateTime(2020, 1, 1), zurich)]
            @test timezone_projection[:dt64_ms] == [
                ZonedDateTime(DateTime(2020, 1, 1, 0, 0, 0, 123), zurich),
            ]
            @test timezone_projection[:dt64_us] == [
                ClickHouseZonedDateTime64{6}(1_577_833_200_123_456, zurich),
            ]

            tuple_proj = query(sock, "SELECT tuple(ddd, tuple(lul, foo)) AS tup FROM $(table) LIMIT 2")
            @test tuple_proj[:tup] == [(td, (UInt64(42), "aa")), (td, (UInt64(1337), "bb"))]

            nothing_proj = query(sock, "SELECT null AS n, array() AS arr FROM $(table) LIMIT 3")
            @test all(ismissing.(nothing_proj[:n]))
            @test all(nothing_proj[:arr] .== Ref(Missing[]))

            proj_df = select_df(sock, "SELECT * FROM $(table) LIMIT 3, 3")
            exp_df = DataFrame(data)
            order = [:lul, :oof, :foo, :ddd]
            @test proj_df[:, order] == exp_df[:, order]
        finally
            cleanup_execute(sock, "DROP TABLE IF EXISTS $(table)")
        end
    end
end

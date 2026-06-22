using ClickHouseClient: Column, chwrite, chread,
         read_col, VarUInt, parse_typestring, result_type, DateTime64,
         ClickHouseZonedDateTime64,
         ClickHouseDecimal32, ClickHouseDecimal64, ClickHouseDecimal128,
         ClickHouseDecimal256, ClickHouseDynamic, ClickHouseTime,
         ClickHouseTime64, ClickHouseVariant
using Dates
using BFloat16s
using BitIntegers
using CategoricalArrays
using UUIDs
using TimeZones
import Sockets
using Sockets: IPv4, IPv6
using DecFP
import JSON3

function roundtrip_column(column::Column)
    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, column)
    return read_col(sock, VarUInt(length(column.data)))
end

@testset "Parse type" begin
    r = parse_typestring("Int32")
    @test r.name == :Int32
    @test_throws ErrorException parse_typestring("KKKK")

    r = parse_typestring("   String  ")
    @test r.name == :String
    @test result_type(r) == Vector{String}

    r = parse_typestring("   Enum8('a' = 10, 'b'=1, 'addd' = 45)  ")

    @test r.name == :Enum8
    @test length(r.args) == 3
    @test r.args[1] == "'a' = 10"
    @test r.args[2] == "'b'=1"
    @test r.args[3] == "'addd' = 45"
    @test result_type(r) == CategoricalVector{String}

    r = parse_typestring("Enum8('a,b' = 1, 'c(1)' = 2, 'd\\'e' = 3)")
    @test r.name == :Enum8
    @test r.args == ["'a,b' = 1", "'c(1)' = 2", "'d\\'e' = 3"]

    r = parse_typestring("Tuple(DateTime64(3, 'UTC, test'), Enum8('x,y' = 1))")
    @test r.name == :Tuple
    @test r.args[1].name == :DateTime64
    @test r.args[1].args == ["3", "'UTC, test'"]
    @test r.args[2].name == :Enum8
    @test r.args[2].args == ["'x,y' = 1"]

    r = parse_typestring(" FixedString(4)")
    @test r.name == :FixedString
    @test r.args[1] == "4"
    r = parse_typestring(" FixedString(44)")
    @test r.name == :FixedString
    @test r.args[1] == "44"
    @test result_type(r) == Vector{String}

    r = parse_typestring("Tuple(Int64, String)")
    @test r.name == :Tuple
    @test r.args[1].name == :Int64
    @test r.args[2].name == :String
    @test result_type(r) == Vector{Tuple{Int64, String}}

    r = parse_typestring("Tuple(a Int64, `display name` String)")
    @test r.name == :Tuple
    @test r.args[1].name == :Int64
    @test r.args[2].name == :String
    @test result_type(r) == Vector{Tuple{Int64, String}}

    r = parse_typestring("Tuple(items Array(UInt8), maybe Nullable(String))")
    @test r.name == :Tuple
    @test r.args[1].name == :Array
    @test r.args[2].name == :Nullable
    @test result_type(r) == Vector{Tuple{Vector{UInt8}, Union{Missing, String}}}

    r = parse_typestring("Tuple(Enum16('a' = 10), Tuple(Int32, Float32))")
    @test r.name == :Tuple
    @test r.args[1].name == :Enum16
    @test r.args[1].args[1] == "'a' = 10"
    @test r.args[2].name == :Tuple
    @test r.args[2].args[1].name == :Int32
    @test r.args[2].args[2].name == :Float32
    @test result_type(r) == Vector{
        Tuple{
            CategoricalValue{String},
            Tuple{Int32, Float32}
            }
        }

    r = parse_typestring("LowCardinality(String)")
    @test result_type(r) == CategoricalVector{String}

    r = parse_typestring("Array(Array(Nullable(Int32)))")
    @test result_type(r) == Vector{
        Vector{
            Vector{Union{Missing, Int32}}
        }
    }

    @test result_type(parse_typestring("Int128")) == Vector{Int128}
    @test result_type(parse_typestring("UInt128")) == Vector{UInt128}
    @test result_type(parse_typestring("Int256")) == Vector{Int256}
    @test result_type(parse_typestring("UInt256")) == Vector{UInt256}
    @test result_type(parse_typestring("BFloat16")) == Vector{BFloat16}
    @test result_type(parse_typestring("Date32")) == Vector{Date}
    @test result_type(parse_typestring("Time")) == Vector{ClickHouseTime}
    @test result_type(parse_typestring("Time64(6)")) == Vector{ClickHouseTime64{6}}
    @test result_type(parse_typestring("DateTime('Europe/Zurich')")) ==
        Vector{ZonedDateTime}
    @test result_type(parse_typestring("DateTime64(3, 'Europe/Zurich')")) ==
        Vector{ZonedDateTime}
    @test result_type(parse_typestring("DateTime64(6, 'Europe/Zurich')")) ==
        Vector{ClickHouseZonedDateTime64{6}}
    @test result_type(parse_typestring("Decimal32(3)")) == Vector{ClickHouseDecimal32{3}}
    @test result_type(parse_typestring("Decimal64(4)")) == Vector{ClickHouseDecimal64{4}}
    @test result_type(parse_typestring("Decimal128(14)")) == Vector{ClickHouseDecimal128{14}}
    @test result_type(parse_typestring("Decimal256(12)")) == Vector{ClickHouseDecimal256{12}}
    @test result_type(parse_typestring("Decimal(10)")) == Vector{ClickHouseDecimal64{0}}
    @test result_type(parse_typestring("Decimal(20,14)")) == Vector{ClickHouseDecimal128{14}}
    @test result_type(parse_typestring("Decimal(76,12)")) == Vector{ClickHouseDecimal256{12}}
    @test result_type(parse_typestring("JSON")) == Vector{JSON3.Object}
    @test result_type(parse_typestring("Map(String, UInt64)")) ==
        Vector{Vector{Pair{String, UInt64}}}

    r = parse_typestring("Variant(Int32, String)")
    @test r.name == :Variant
    @test result_type(r) == Vector{
        Union{
            Missing,
            ClickHouseVariant{1, Int32},
            ClickHouseVariant{2, String}
        }
    }

    @test result_type(parse_typestring("Dynamic")) ==
        Vector{Union{Missing, ClickHouseClient.AbstractClickHouseDynamic}}
    @test !ClickHouseClient.can_be_nullable(:Tuple)

    @test_throws ErrorException parse_typestring("")
    @test_throws ErrorException parse_typestring("Array")
    @test_throws ErrorException parse_typestring("Array()")
    @test_throws ErrorException parse_typestring("Array('x')")
    @test_throws ErrorException parse_typestring("Map(String)")
    @test_throws ErrorException parse_typestring("Nullable()")
    @test_throws ErrorException parse_typestring("DateTime64()")
    @test_throws ErrorException parse_typestring("FixedString(Int8)")
    @test_throws ErrorException parse_typestring("Dynamic(max_types=1)")
    @test_throws ErrorException parse_typestring("JSON(max_dynamic_paths=1)")

end

@testset "Empty stateful columns" begin
    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, Column("lc", "LowCardinality(String)", CategoricalVector(String[])))
    chwrite(sock, Column("v", "Variant(Int32, String)", Any[]))
    chwrite(sock, Column("d", "Dynamic", Any[]))
    chwrite(sock, Column("j", "JSON", JSON3.Object[]))
    chwrite(sock, Column("x", "UInt8", UInt8[]))

    @test read_col(sock, VarUInt(0)).type == "LowCardinality(String)"
    @test read_col(sock, VarUInt(0)).type == "Variant(Int32, String)"
    @test read_col(sock, VarUInt(0)).type == "Dynamic"
    @test read_col(sock, VarUInt(0)).type == "JSON"
    @test read_col(sock, VarUInt(0)).type == "UInt8"
    @test bytesavailable(sock.io) == 0
end

@testset "IP columns" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = Sockets.IPv4.(rand(UInt32, nrows))
    column = Column("test", "IPv4", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res == column

    column = Column("test", "IPv4", IPv4[IPv4(0), IPv4(typemax(UInt32))])
    @test roundtrip_column(column) == column

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = Sockets.IPv6.(rand(UInt128, nrows))
    column = Column("test", "IPv6", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res == column

    column = Column("test", "IPv6", IPv6[IPv6(0), IPv6(typemax(UInt128))])
    @test roundtrip_column(column) == column

    ipv6_wire = UInt8[
        0x20, 0x01, 0x0d, 0xb8,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01,
    ]
    ipv6 = IPv6("2001:db8::1")

    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, "test")
    chwrite(sock, "IPv6")
    write(sock.io, ipv6_wire)
    res = read_col(sock, VarUInt(1))
    @test res.data == IPv6[ipv6]

    sock = ClickHouseSock(PipeBuffer())
    ClickHouseClient.write_col_data(sock, IPv6[ipv6], Val(:IPv6))
    @test read(sock.io) == ipv6_wire

end

@testset "Extended primitive columns" begin

    columns = [
        Column("test", "Int128", Int128[-(Int128(1) << 80), -1, 0, Int128(1) << 80]),
        Column("test", "UInt128", UInt128[0, 1, UInt128(1) << 80, typemax(UInt128)]),
        Column("test", "Int256", Int256[-(Int256(1) << 200), -1, 0, Int256(1) << 200]),
        Column("test", "UInt256", UInt256[0, 1, UInt256(1) << 200, typemax(UInt256)]),
        Column("test", "BFloat16", BFloat16.(Float32[-2.25, 0.0, 1.5])),
    ]

    for column in columns
        @test roundtrip_column(column) == column
    end

end

@testset "Primitive scalar columns" begin
    columns = [
        Column("test", "UInt8", UInt8[0, typemax(UInt8)]),
        Column("test", "UInt16", UInt16[0, typemax(UInt16)]),
        Column("test", "UInt32", UInt32[0, typemax(UInt32)]),
        Column("test", "UInt64", UInt64[0, typemax(UInt64)]),
        Column("test", "Int8", Int8[typemin(Int8), -1, 0, typemax(Int8)]),
        Column("test", "Int16", Int16[typemin(Int16), -1, 0, typemax(Int16)]),
        Column("test", "Int32", Int32[typemin(Int32), -1, 0, typemax(Int32)]),
        Column("test", "Int64", Int64[typemin(Int64), -1, 0, typemax(Int64)]),
        Column("test", "Bool", Bool[false, true, false]),
    ]

    for column in columns
        @test roundtrip_column(column) == column
    end

    data32 = Float32[-Inf32, -0.0f0, 0.0f0, 1.5f0, Inf32, NaN32]
    res32 = roundtrip_column(Column("test", "Float32", data32))
    @test isequal(res32.data, data32)

    data64 = Float64[-Inf, -0.0, 0.0, 1.5, Inf, NaN]
    res64 = roundtrip_column(Column("test", "Float64", data64))
    @test isequal(res64.data, data64)

    bfloat_data = BFloat16.(Float32[-Inf32, -0.0f0, 0.0f0, 1.5f0, Inf32, NaN32])
    res = roundtrip_column(Column("test", "BFloat16", bfloat_data))
    @test isequal(res.data, bfloat_data)
end

@testset "Int columns" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = rand(Int64, nrows)
    column = Column("test", "Int64", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res == column

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = rand(Int32, nrows)
    column = Column("test", "Int64", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res == column

end

@testset "String columns" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = string.(rand(Int64, nrows))
    column = Column("test", "String", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res == column

    data = ["", "ascii", "unicode é", "has\0nul", repeat("x", 512)]
    column = Column("test", "String", data)
    @test roundtrip_column(column) == column

end

@testset "Fixed String columns" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = string.(rand(["aaaa", "bbbb", "cccc", "dddd"], nrows))
    column = Column("test", "FixedString(4)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res == column

    sock = ClickHouseSock(PipeBuffer())
    data = string.(rand(["aaaaa", "bbbb", "cccc", "dddd"], nrows))
    column = Column("test", "FixedString(4)", data)
    @test_throws ErrorException chwrite(sock, column)


    sock = ClickHouseSock(PipeBuffer())
    data = string.(rand(["aaaa", "bbbb", "cccc", "dddd"], nrows))
    column = Column("test", "FixedString(5)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test all(s -> sizeof(s) == 5, res.data)
    @test res.data == data .* "\0"

    column = Column("test", "FixedString(2)", [""])
    res = roundtrip_column(column)
    @test res.data == ["\0\0"]

    sock = ClickHouseSock(PipeBuffer())
    data = ["é"]
    column = Column("test", "FixedString(3)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(1))
    @test res.data == ["é\0"]

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "FixedString(3)", ["éé"])
    @test_throws ErrorException chwrite(sock, column)

    settings = ClickHouseClient.CHSettings(host = "", username = "", max_string_size = 20)
    sock = ClickHouseSock(PipeBuffer(), settings)
    chwrite(sock, "t")
    chwrite(sock, "FixedString(21)")
    @test_throws ErrorException read_col(sock, VarUInt(1))

    settings = ClickHouseClient.CHSettings(host = "", username = "", max_column_size_bytes = 3)
    sock = ClickHouseSock(PipeBuffer(), settings)
    chwrite(sock, "test")
    chwrite(sock, "FixedString(2)")
    @test_throws ErrorException read_col(sock, VarUInt(2))

    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, "test")
    chwrite(sock, "FixedString(4)")
    write(sock.io, UInt8[0x61, 0x62])
    @test_throws EOFError read_col(sock, VarUInt(1))
end

@testset "Date columns" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = Date.(rand(2010:2020, nrows), rand(1:12, nrows), rand(1:20, nrows))
    column = Column("test", "Date", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res == column

    column = Column("test", "Date", [Date(1970, 1, 1), Date(2149, 6, 6)])
    @test roundtrip_column(column) == column

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "Date", [Date(1969, 12, 31)])
    @test_throws DomainError chwrite(sock, column)

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "Date", [Date(2149, 6, 7)])
    @test_throws DomainError chwrite(sock, column)

end

@testset "Date32 columns" begin

    data = [Date(1900, 1, 1), Date(1970, 1, 1), Date(2299, 12, 31)]
    column = Column("test", "Date32", data)
    @test roundtrip_column(column) == column

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "Date32", [Date(1899, 12, 31)])
    @test_throws DomainError chwrite(sock, column)

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "Date32", [Date(2300, 1, 1)])
    @test_throws DomainError chwrite(sock, column)

end

@testset "DateTime columns" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = DateTime.(rand(2010:2020, nrows), rand(1:12, nrows), rand(1:20, nrows),
    rand(0:23, nrows), rand(0:59, nrows), rand(0:59, nrows))
    column = Column("test", "DateTime", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res == column

    sock = ClickHouseSock(PipeBuffer())
    data = [DateTime(2040, 1, 1)]
    column = Column("test", "DateTime", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(1))
    @test res == column

    column = Column("test", "DateTime", [DateTime(1970, 1, 1), unix2datetime(typemax(UInt32))])
    @test roundtrip_column(column) == column

    tz = TimeZone("Europe/Zurich")
    zoned_data = ZonedDateTime[
        ZonedDateTime(DateTime(2020, 1, 1), tz),
        ZonedDateTime(DateTime(2020, 7, 1, 12), tz),
    ]
    column = Column("test", "DateTime('Europe/Zurich')", zoned_data)
    @test roundtrip_column(column) == column

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "DateTime", [DateTime(2020, 1, 1, 0, 0, 0, 1)])
    @test_throws ErrorException chwrite(sock, column)

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "DateTime", [DateTime(1969, 12, 31, 23, 59, 59)])
    @test_throws DomainError chwrite(sock, column)

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "DateTime", [unix2datetime(typemax(UInt32)) + Second(1)])
    @test_throws DomainError chwrite(sock, column)

end

@testset "Time columns" begin

    data = ClickHouseTime.(Int32[0, 1, 3_661, 86_399])
    column = Column("test", "Time", data)
    @test roundtrip_column(column) == column

    time_data = [Time(0), Time(1, 2, 3), Time(23, 59, 59)]
    column = Column("test", "Time", time_data)
    res = roundtrip_column(column)
    @test res.data == ClickHouseTime.(time_data)

    data64 = ClickHouseTime64{6}.(Int64[-1, 0, 1_234_567, 86_399_000_000])
    column = Column("test", "Time64(6)", data64)
    @test roundtrip_column(column) == column

    time64_zero = [Time(0), Time(1, 2, 3), Time(23, 59, 59)]
    column = Column("test", "Time64(0)", time64_zero)
    res = roundtrip_column(column)
    @test res.data == ClickHouseTime64.(time64_zero, 0)

    time64_micro = [Time(0), Time(1, 2, 3, 4, 5, 0)]
    column = Column("test", "Time64(6)", time64_micro)
    res = roundtrip_column(column)
    @test res.data == ClickHouseTime64.(time64_micro, 6)

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "Time", [Time(1, 2, 3, 4)])
    @test_throws ErrorException chwrite(sock, column)

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "Time64(6)", [Time(0, 0, 0, 0, 0, 1)])
    @test_throws ErrorException chwrite(sock, column)

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "Time64(6)", ClickHouseTime64{3}[ClickHouseTime64{3}(1)])
    @test_throws ErrorException chwrite(sock, column)

end

@testset "DateTime64 columns" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = DateTime.(rand(2010:2020, nrows), rand(1:12, nrows), rand(1:20, nrows),
    rand(0:23, nrows), rand(0:59, nrows), rand(0:59, nrows))
    column = Column("test", "DateTime64(0)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res.data == DateTime64.(data, 0)

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = DateTime.(rand(2010:2020, nrows), rand(1:12, nrows), rand(1:20, nrows),
    rand(0:23, nrows), rand(0:59, nrows), rand(0:59, nrows))
    column = Column("test", "DateTime64(2)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res.data == DateTime64.(data, 2)

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = DateTime.(rand(2010:2020, nrows), rand(1:12, nrows), rand(1:20, nrows),
    rand(0:23, nrows), rand(0:59, nrows), rand(0:59, nrows),
    rand(1:999))
    column = Column("test", "DateTime64(3)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res.data == DateTime64.(data, 3)

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = DateTime.(rand(2010:2020, nrows), rand(1:12, nrows), rand(1:20, nrows),
    rand(0:23, nrows), rand(0:59, nrows), rand(0:59, nrows),
    rand(1:999))
    column = Column("test", "DateTime64(6)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res.data == DateTime64.(data, 6)

    sock = ClickHouseSock(PipeBuffer())
    data = DateTime64{9}.([1, 1_234_567_890, -1])
    column = Column("test", "DateTime64(9)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(length(data)))
    @test res == column
    @test DateTime64{3}(1000) == DateTime64{6}(1_000_000)
    @test hash(DateTime64{3}(1000)) == hash(DateTime64{6}(1_000_000))
    @test DateTime64{3}(999) < DateTime64{3}(1000)
    @test DateTime64{3}(1000) < DateTime64{6}(1_000_001)
    @test !(DateTime64{3}(1000) < DateTime64{6}(1_000_000))

    tz = TimeZone("Europe/Zurich")
    zoned_data = ZonedDateTime[
        ZonedDateTime(DateTime(2020, 1, 1, 0, 0, 0, 100), tz),
        ZonedDateTime(DateTime(2020, 7, 1, 12, 0, 0, 200), tz),
    ]
    column = Column("test", "DateTime64(3, 'Europe/Zurich')", zoned_data)
    @test roundtrip_column(column) == column

    column = Column("test", "DateTime64(6, 'Europe/Zurich')", zoned_data)
    res = roundtrip_column(column)
    @test res.data == [
        ClickHouseZonedDateTime64(
            DateTime64(DateTime(2019, 12, 31, 23, 0, 0, 100), 6),
            tz,
        ),
        ClickHouseZonedDateTime64(
            DateTime64(DateTime(2020, 7, 1, 10, 0, 0, 200), 6),
            tz,
        ),
    ]

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "DateTime64(1)", [DateTime(2020, 1, 1, 0, 0, 0, 1)])
    @test_throws ErrorException chwrite(sock, column)

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "DateTime64(3)", [DateTime(1899, 12, 31, 23, 59, 59)])
    @test_throws DomainError chwrite(sock, column)

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "DateTime64(3)", [DateTime(2300, 1, 1)])
    @test_throws DomainError chwrite(sock, column)

end




@testset "Enum columns" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = rand(["a","b","c"], nrows)
    column = Column("test", "Enum8('a'=1,'b'=3,'c'=10)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res == column

    column = Column("test", "Enum8('d\\'e'=1,'line\\nfeed'=2)", ["d'e", "line\nfeed"])
    @test roundtrip_column(column) == column

    column = Column("test", "Enum16('low'=1,'high'=300)", ["low", "high", "low"])
    @test roundtrip_column(column) == column

    column = Column("test", "Enum8('b'=2,'a'=1)", ["b", "a"])
    res = roundtrip_column(column)
    @test levels(res.data) == ["b", "a"]
    @test res == column

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "Enum8('a'=1)", ["a", "b"])
    @test_throws ErrorException chwrite(sock, column)

    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, "test")
    chwrite(sock, "Enum8('a'=1)")
    chwrite(sock, Int8[2])
    @test_throws ErrorException read_col(sock, VarUInt(1))

end

@testset "Enum columns categorial in" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = CategoricalVector(rand(["a","b","c"], nrows))
    column = Column("test", "Enum8('a'=1,'b'=3,'c'=10)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))

    @test res == column

end


@testset "UUID columns" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = Vector{UUID}(undef, nrows)
    data .= uuid4()
    column = Column("test", "UUID", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res == column

    uuid_wire = UInt8[
        0x77, 0x66, 0x55, 0x44,
        0x33, 0x22, 0x11, 0x00,
        0xff, 0xee, 0xdd, 0xcc,
        0xbb, 0xaa, 0x99, 0x88,
    ]
    uuid = UUID("00112233-4455-6677-8899-aabbccddeeff")

    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, "test")
    chwrite(sock, "UUID")
    write(sock.io, uuid_wire)
    res = read_col(sock, VarUInt(1))
    @test res.data == UUID[uuid]

    sock = ClickHouseSock(PipeBuffer())
    ClickHouseClient.write_col_data(sock, UUID[uuid], Val(:UUID))
    @test read(sock.io) == uuid_wire

end

@testset "Tuple columns" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = tuple.(rand(Int64, nrows), rand(Int8, nrows))
    column = Column("test", "Tuple(Int64, Int8)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res == column

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = tuple.(rand(Int64, nrows), string.(rand(Int8, nrows)))
    column = Column("test", "Tuple(Int64, String)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res == column

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = tuple.(
        rand(["aa", "bb", "ccc"], nrows),
        tuple.(rand(Int16, nrows))
        )
    column = Column("test", "Tuple(Enum16('aa' = 1, 'bb' = 2, 'ccc' = 10), Tuple(Int16))", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res == column

    column = Column("test", "Tuple(Int64, String)", Tuple{Int64, String}[])
    res = roundtrip_column(column)
    @test isempty(res.data)
    @test res.data isa Vector{Tuple{Int64, String}}

    column = Column("test", "Tuple(Int64, Int64)", Tuple[(1, 2), (3, 4, 5)])
    @test_throws ErrorException roundtrip_column(column)

end

@testset "Map columns" begin
    data = Vector{Pair{String, UInt64}}[
        ["a" => UInt64(1), "b" => UInt64(2)],
        ["z" => UInt64(3)],
    ]
    column = Column("test", "Map(String, UInt64)", data)
    @test roundtrip_column(column) == column

    dict_data = [Dict("a" => Int64(1)), Dict("b" => Int64(2))]
    column = Column("test", "Map(String, Int64)", dict_data)
    res = roundtrip_column(column)
    @test res.data == Vector{Pair{String, Int64}}[
        ["a" => Int64(1)],
        ["b" => Int64(2)],
    ]

    duplicate_data = Vector{Pair{String, Int64}}[
        ["a" => Int64(1), "a" => Int64(2)],
        Pair{String, Int64}[],
    ]
    column = Column("test", "Map(String, Int64)", duplicate_data)
    res = roundtrip_column(column)
    @test res.data == duplicate_data

    int_key_data = Vector{Pair{UInt8, String}}[
        [UInt8(1) => "one", UInt8(2) => "two"],
        Pair{UInt8, String}[],
    ]
    column = Column("test", "Map(UInt8, String)", int_key_data)
    @test roundtrip_column(column) == column

    nullable_row = Pair{String, Union{Missing, Int64}}[
        Pair{String, Union{Missing, Int64}}("missing", missing),
        Pair{String, Union{Missing, Int64}}("present", Int64(1)),
    ]
    column = Column("test", "Map(String, Nullable(Int64))", [nullable_row])
    res = roundtrip_column(column)
    @test res.data[1][1].first == "missing"
    @test ismissing(res.data[1][1].second)
    @test res.data[1][2] == ("present" => Int64(1))

    column = Column(
        "test",
        "Array(Map(String, Int64))",
        [Vector{Pair{String, Int64}}[]],
    )
    res = roundtrip_column(column)
    @test res.data == [Vector{Pair{String, Int64}}[]]
end

@testset "Nullable columns" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = rand(Int64, nrows)
    data = convert(Vector{Union{Int64, Missing}}, data)
    data[rand(1:nrows, 20)] .= missing
    column = Column("test", "Nullable(Int64)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test all(zip(data, res.data)) do t
        (a, b) = t
        return (ismissing(a) && ismissing(b)) ||
        (a == b)
    end

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = rand(Float64, nrows)
    data = convert(Vector{Union{Float64, Missing}}, data)
    data[rand(1:nrows, 20)] .= missing
    column = Column("test", "Nullable(Float64)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test all(zip(data, res.data)) do t
        (a, b) = t
        return (ismissing(a) && ismissing(b)) ||
        (a ≈ b)
    end

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = string.(rand(Int64, nrows))
    data = convert(Vector{Union{String, Missing}}, data)
    data[rand(1:nrows, 20)] .= missing
    column = Column("test", "Nullable(String)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test all(zip(data, res.data)) do t
        (a, b) = t
        return (ismissing(a) && ismissing(b)) ||
        (a == b)
    end


    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = CategoricalVector(rand(["a","b","c", missing], nrows))

    data[rand(1:nrows, 20)] .= missing

    column = Column("test", "Nullable(Enum8('a'=1,'b'=3,'c'=10))", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))

    @test all(zip(data, res.data)) do t
        (a, b) = t
        return (ismissing(a) && ismissing(b)) ||
        (a == b)
    end

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = Date.(rand(2010:2020, nrows), rand(1:12, nrows), rand(1:20, nrows))
    data = convert(Vector{Union{Date, Missing}}, data)
    data[rand(1:nrows, 20)] .= missing
    column = Column("test", "Nullable(Date)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test all(zip(data, res.data)) do t
        (a, b) = t
        return (ismissing(a) && ismissing(b)) ||
        (a == b)
    end

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = DateTime.(rand(2010:2020, nrows), rand(1:12, nrows), rand(1:20, nrows),
    rand(0:23, nrows), rand(0:59, nrows), rand(0:59, nrows))
    data = convert(Vector{Union{DateTime, Missing}}, data)
    data[rand(1:nrows, 20)] .= missing
    column = Column("test", "Nullable(DateTime)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test all(zip(data, res.data)) do t
        (a, b) = t
        return (ismissing(a) && ismissing(b)) ||
        (a == b)
    end

    data = Union{Missing, UInt64}[missing, missing, missing]
    column = Column("test", "Nullable(UInt64)", data)
    res = roundtrip_column(column)
    @test all(ismissing.(res.data))

    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, "test")
    chwrite(sock, "Nullable(Int64)")
    chwrite(sock, UInt8[0x02])
    chwrite(sock, Int64[123])
    @test_throws ErrorException read_col(sock, VarUInt(1))
end

@testset "LowCardinality columns" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 10
    data = rand(1:10, nrows)
    column = Column("test", "LowCardinality(Int64)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))

    @test res.data == data

    sock = ClickHouseSock(PipeBuffer())
    data = rand(1:10, nrows)
    data = convert(Vector{Union{Int64, Missing}}, data)
    data[rand(1:nrows, 5)] .= missing
    column = Column("test", "LowCardinality(Nullable(Int64))", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))

    @test all(zip(data, res.data)) do t
        (a, b) = t
        return (ismissing(a) && ismissing(b)) ||
        (a == b)
    end

    data = Int64[1, 2, 1]
    column = Column("test", "LowCardinality(Nullable(Int64))", data)
    res = roundtrip_column(column)
    @test res.data == data

    sock = ClickHouseSock(PipeBuffer())
    data = rand(["a", "b", "c"], nrows)
    column = Column("test", "LowCardinality(String)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))

    @test res.data == data

    sock = ClickHouseSock(PipeBuffer())
    data = CategoricalVector(rand(["a","b","c"], nrows))

    column = Column("test", "LowCardinality(Enum8('a'=1,'b'=3,'c'=10))", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res.data == data

    sock = ClickHouseSock(PipeBuffer())
    data = string.("v", 1:256)
    column = Column("test", "LowCardinality(String)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(length(data)))
    @test res.data == data

    sock = ClickHouseSock(PipeBuffer())
    data = string.("v", 1:257)
    column = Column("test", "LowCardinality(String)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(length(data)))
    @test res.data == data

    column = Column("test", "LowCardinality(String)", String[])
    res = roundtrip_column(column)
    @test isempty(res.data)
    @test res.data isa CategoricalVector{String}

    data = CategoricalVector(["a", "b", "a"])
    column = Column("test", "LowCardinality(Nullable(String))", data)
    res = roundtrip_column(column)
    @test res.data == data

    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, "test")
    chwrite(sock, "LowCardinality(String)")
    chwrite(sock, UInt64(1))
    chwrite(sock, UInt64(ClickHouseClient.lc_serialization_type))
    chwrite(sock, UInt64(1))
    chwrite(sock, "only")
    chwrite(sock, UInt64(1))
    chwrite(sock, UInt8[0x01])
    @test_throws ErrorException read_col(sock, VarUInt(1))

    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, "test")
    chwrite(sock, "LowCardinality(String)")
    chwrite(sock, UInt64(1))
    chwrite(sock, UInt64(ClickHouseClient.lc_serialization_type))
    chwrite(sock, UInt64(1))
    chwrite(sock, "only")
    chwrite(sock, UInt64(0))
    @test_throws ErrorException read_col(sock, VarUInt(1))

end

@testset "Array collumns" begin

    nrows = 1000
    sock = ClickHouseSock(PipeBuffer())
    data = rand([[[1,2],[3]], [[3],[4,5]], [[6],[7,8]]], nrows)
    column = Column("test", "Array(Array(Int64))", data)
    chwrite(sock, column)

    res = read_col(sock, VarUInt(nrows))
    @test res.data == data

    sock = ClickHouseSock(PipeBuffer())
    data = Vector{Vector{Int64}}[Vector{Int64}[], Vector{Int64}[]]
    column = Column("test", "Array(Array(Int64))", data)
    chwrite(sock, column)

    res = read_col(sock, VarUInt(length(data)))
    @test res.data == data

    sock = ClickHouseSock(PipeBuffer())
    data = rand([
        ["ab", "bc", "cd"],
        ["ab", "ed", "ab"]
    ], nrows)
    column = Column("test", "Array(String)", data)
    chwrite(sock, column)

    res = read_col(sock, VarUInt(nrows))
    @test res.data == data

    sock = ClickHouseSock(PipeBuffer())
    data = rand([
        ["ab", "bc", "cd"],
        ["ab", "ed", "ab"]
    ], nrows)
    column = Column("test", "Array(LowCardinality(String))", data)
    chwrite(sock, column)

    res = read_col(sock, VarUInt(nrows))
    @test res.data == data
    sock = ClickHouseSock(PipeBuffer())
    data = rand([
        [["ab"], [missing, "cd"]],
        [["ab", "ac"], [missing, "ab"]]
    ], nrows)
    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "Array(Array(Nullable(String)))", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test string(data) == string(res.data)
    @test recursive_miss_cmp(data, res.data)

    sock = ClickHouseSock(PipeBuffer())
    data = Vector{Vector{Union{Missing, String}}}[
        Vector{Union{Missing, String}}[],
        Vector{Union{Missing, String}}[],
    ]
    column = Column("test", "Array(Array(Nullable(String)))", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(length(data)))
    @test recursive_miss_cmp(data, res.data)

    sock = ClickHouseSock(PipeBuffer())
    data = rand([
        [["ab"], [missing, "cd"]],
        [["ab", "ac"], [missing, "ab"]]
    ], nrows)
    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "Array(Array(LowCardinality(Nullable(String))))", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test recursive_miss_cmp(data, res.data)

    column = Column("test", "Array(String)", Vector{String}[])
    res = roundtrip_column(column)
    @test isempty(res.data)
    @test res.data isa Vector{Vector{String}}

    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, "test")
    chwrite(sock, "Array(Int64)")
    chwrite(sock, UInt64[2, 1])
    @test_throws ErrorException read_col(sock, VarUInt(2))

    settings = ClickHouseClient.CHSettings(host = "", username = "", max_column_size_bytes = 7)
    sock = ClickHouseSock(PipeBuffer(), settings)
    chwrite(sock, "test")
    chwrite(sock, "Array(Int64)")
    @test_throws ErrorException read_col(sock, VarUInt(1))
end

@testset "Nothing column" begin
    sock = ClickHouseSock(PipeBuffer())
    data = [missing, missing, missing, missing]
    column = Column("test", "Nullable(Nothing)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(4))
    @test all(ismissing.(res.data))

    sock = ClickHouseSock(PipeBuffer())
    data = [[], [], [], []]
    column = Column("test", "Array(Nothing)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(4))
    @test all(res.data .== Ref(Missing[]))
end

@testset "SimpleAggregateFunction columns" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    data = rand(Int64, nrows)
    column = Column("test", "SimpleAggregateFunction(sum, Int64)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res == column

    data = Union{Missing, Int64}[missing, 10, 20]
    column = Column("test", "SimpleAggregateFunction(any, Nullable(Int64))", data)
    res = roundtrip_column(column)
    @test recursive_miss_cmp(res.data, data)

    column = Column("test", "SimpleAggregateFunction(sum, Int64)", Int64[])
    res = roundtrip_column(column)
    @test isempty(res.data)
    @test res.data isa Vector{Int64}

end


@testset "Decimal columns" begin

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    raw32 = Int32.(rand(1000:9999, nrows))
    data = Dec32.(raw32, -3)
    column = Column("test", "Decimal32(3)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res.data == ClickHouseDecimal32{3}.(raw32)

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "Decimal(4,3)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res.data == ClickHouseDecimal32{3}.(raw32)

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    raw64 = rand(1_000_000_000:9_999_999_999, nrows)
    data = Dec64.(raw64, -4)
    column = Column("test", "Decimal64(4)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res.data == ClickHouseDecimal64{4}.(raw64)

    sock = ClickHouseSock(PipeBuffer())
    column = Column("test", "Decimal(10,4)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res.data == ClickHouseDecimal64{4}.(raw64)

    column = Column("test", "Decimal(10)", ClickHouseDecimal64{0}[ClickHouseDecimal64{0}(123)])
    @test roundtrip_column(column).data == column.data

    sock = ClickHouseSock(PipeBuffer())
    nrows = 100
    raw128 = rand(Int128(10)^20:(Int128(10)^21 - 1), nrows)
    data = Dec128.(raw128, -14)
    column = Column("test", "Decimal128(14)", data)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res.data == ClickHouseDecimal128{14}.(raw128)

    sock = ClickHouseSock(PipeBuffer())
    raw128_p20 = rand((Int128(10)^19):(Int128(10)^20 - 1), nrows)
    data_p20 = Dec128.(raw128_p20, -14)
    column = Column("test", "Decimal(20,14)", data_p20)
    chwrite(sock, column)
    res = read_col(sock, VarUInt(nrows))
    @test res.data == ClickHouseDecimal128{14}.(raw128_p20)

    @test roundtrip_column(Column(
        "test",
        "Decimal32(0)",
        ClickHouseDecimal32{0}[ClickHouseDecimal32{0}(999_999_999)],
    )).data == ClickHouseDecimal32{0}[ClickHouseDecimal32{0}(999_999_999)]
    @test roundtrip_column(Column(
        "test",
        "Decimal64(0)",
        ClickHouseDecimal64{0}[ClickHouseDecimal64{0}(999_999_999_999_999_999)],
    )).data == ClickHouseDecimal64{0}[
        ClickHouseDecimal64{0}(999_999_999_999_999_999)
    ]
    decimal128_max = parse(Int128, "99999999999999999999999999999999999999")
    @test roundtrip_column(Column(
        "test",
        "Decimal128(0)",
        ClickHouseDecimal128{0}[ClickHouseDecimal128{0}(decimal128_max)],
    )).data == ClickHouseDecimal128{0}[ClickHouseDecimal128{0}(decimal128_max)]

    data = ClickHouseDecimal256{6}.(Int256[-123_456_789, 0, 987_654_321])
    column = Column("test", "Decimal256(6)", data)
    @test roundtrip_column(column) == column

    column = Column("test", "Decimal(76,6)", data)
    @test roundtrip_column(column) == column

    @test roundtrip_column(Column(
        "test",
        "Decimal32(2)",
        ClickHouseDecimal32{2}.(Int32[-123, 0, 456]),
    )).data == ClickHouseDecimal32{2}.(Int32[-123, 0, 456])
    @test roundtrip_column(Column(
        "test",
        "Decimal64(4)",
        ClickHouseDecimal64{4}.(Int64[-123_456, 0, 789_000]),
    )).data == ClickHouseDecimal64{4}.(Int64[-123_456, 0, 789_000])
    @test roundtrip_column(Column(
        "test",
        "Decimal128(14)",
        ClickHouseDecimal128{14}.(Int128[-123_456, 0, 789_000]),
    )).data == ClickHouseDecimal128{14}.(Int128[-123_456, 0, 789_000])

    @test_throws DomainError ClickHouseDecimal32{0}(1_000_000_000)
    @test_throws DomainError ClickHouseDecimal64{0}(1_000_000_000_000_000_000)
    @test_throws ArgumentError result_type(parse_typestring("Decimal(4,5)"))
    @test_throws DomainError roundtrip_column(Column(
        "test",
        "Decimal(4,3)",
        ClickHouseDecimal32{3}[ClickHouseDecimal32{3}(10_000)],
    ))

    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, "test")
    chwrite(sock, "Decimal(4,3)")
    chwrite(sock, Int32[10_000])
    @test_throws DomainError read_col(sock, VarUInt(1))

    @test_throws ErrorException roundtrip_column(Column(
        "test",
        "Decimal32(2)",
        ClickHouseDecimal32{3}[ClickHouseDecimal32{3}(123)],
    ))
    @test_throws ErrorException roundtrip_column(Column(
        "test",
        "Decimal32(2)",
        Dec32[Dec32(1234, -3)],
    ))
    @test_throws InexactError roundtrip_column(Column(
        "test",
        "Decimal32(0)",
        [Int64(typemax(Int32)) + 1],
    ))

end

@testset "Variant columns" begin

    data = Union{
        Missing,
        ClickHouseVariant{1, Int32},
        ClickHouseVariant{2, String}
    }[
        ClickHouseVariant{1}(Int32(42)),
        ClickHouseVariant{2}("forty-two"),
        missing,
        ClickHouseVariant{1}(Int32(-7)),
    ]
    column = Column("test", "Variant(Int32, String)", data)
    res = roundtrip_column(column)
    @test res.name == column.name
    @test res.type == column.type
    @test isequal(res.data, column.data)

    raw = Any[Int32(1), "two", missing, Int32(3)]
    column = Column("test", "Variant(Int32, String)", raw)
    res = roundtrip_column(column)
    @test isequal(res.data, Union{
        Missing,
        ClickHouseVariant{1, Int32},
        ClickHouseVariant{2, String}
    }[
        ClickHouseVariant{1}(Int32(1)),
        ClickHouseVariant{2}("two"),
        missing,
        ClickHouseVariant{1}(Int32(3)),
    ])

    @test_throws ErrorException roundtrip_column(Column(
        "test",
        "Variant(Int64, Int64)",
        Any[Int64(1)],
    ))
    @test_throws ErrorException roundtrip_column(Column(
        "test",
        "Variant(Int32, String)",
        Any[ClickHouseVariant{3}(Int32(1))],
    ))

    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, "test")
    chwrite(sock, "Variant(Int32, String)")
    chwrite(sock, UInt64(1))
    chwrite(sock, VarUInt(3))
    chwrite(sock, UInt8(0))
    chwrite(sock, UInt8[0x00, 0x01, 0xff])
    chwrite(sock, Int32[42])
    chwrite(sock, String["forty-two"])
    res = read_col(sock, VarUInt(3))
    @test isequal(res.data, Union{
        Missing,
        ClickHouseVariant{1, Int32},
        ClickHouseVariant{2, String}
    }[
        ClickHouseVariant{1}(Int32(42)),
        ClickHouseVariant{2}("forty-two"),
        missing,
    ])

    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, "test")
    chwrite(sock, "Variant(Int32, String)")
    chwrite(sock, UInt64(0))
    chwrite(sock, UInt8[0x02])
    @test_throws ErrorException read_col(sock, VarUInt(1))

    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, "test")
    chwrite(sock, "Variant(Int32, String)")
    chwrite(sock, UInt64(1))
    chwrite(sock, VarUInt(0))
    chwrite(sock, UInt8(0))
    @test_throws ErrorException read_col(sock, VarUInt(1))

end

@testset "Dynamic columns" begin

    data = Any[
        Int32(42),
        "forty-two",
        missing,
        true,
        ClickHouseTime(3_661),
    ]
    column = Column("test", "Dynamic", data)
    res = roundtrip_column(column)

    @test ismissing(res.data[3])
    @test res.data[1] == ClickHouseDynamic("Int32", Int32(42))
    @test res.data[2] == ClickHouseDynamic("String", "forty-two")
    @test res.data[4] == ClickHouseDynamic("Bool", true)
    @test res.data[5] == ClickHouseDynamic("Time", ClickHouseTime(3_661))

    uuid = UUID("00112233-4455-6677-8899-aabbccddeeff")
    ipv4 = IPv4("192.0.2.1")
    ipv6 = IPv6("2001:db8::1")
    data = Any[
        UInt64(7),
        Float64(1.5),
        Date(2020, 1, 2),
        DateTime(2020, 1, 2, 3, 4, 5),
        DateTime64{6}(1_234_567),
        ClickHouseTime64{6}(3_661_000_000),
        uuid,
        ipv4,
        ipv6,
        ClickHouseDecimal64{2}(1234),
        BFloat16(1.5f0),
    ]
    column = Column("test", "Dynamic", data)
    res = roundtrip_column(column)
    @test isequal(res.data, [
        ClickHouseDynamic("UInt64", UInt64(7)),
        ClickHouseDynamic("Float64", Float64(1.5)),
        ClickHouseDynamic("Date32", Date(2020, 1, 2)),
        ClickHouseDynamic("DateTime", DateTime(2020, 1, 2, 3, 4, 5)),
        ClickHouseDynamic("DateTime64", DateTime64{6}(1_234_567)),
        ClickHouseDynamic("Time64", ClickHouseTime64{6}(3_661_000_000)),
        ClickHouseDynamic("UUID", uuid),
        ClickHouseDynamic("IPv4", ipv4),
        ClickHouseDynamic("IPv6", ipv6),
        ClickHouseDynamic("Decimal", ClickHouseDecimal64{2}(1234)),
        ClickHouseDynamic("BFloat16", BFloat16(1.5f0)),
    ])

    @test_throws ErrorException roundtrip_column(Column("test", "Dynamic", Any[[1, 2, 3]]))

    sock = ClickHouseSock(PipeBuffer())
    chwrite(sock, "test")
    chwrite(sock, "Dynamic")
    chwrite(sock, UInt64(2))
    chwrite(sock, VarUInt(0))
    chwrite(sock, UInt64(0))
    chwrite(sock, UInt8[0x00])
    chwrite(sock, String[String(UInt8[0x2d, 0x02])])
    @test_throws ErrorException read_col(sock, VarUInt(1))

end

@testset "JSON columns" begin

    json_strings = [
        """{"a":1,"b":"x"}""",
        """{"c":[1,2],"d":true}""",
    ]
    data = JSON3.read.(json_strings)
    column = Column("test", "JSON", data)
    res = roundtrip_column(column)

    @test JSON3.write.(res.data) == json_strings

    json_strings = [
        "{}",
        """{"x":1,"nested":{"ok":true}}""",
    ]
    column = Column("test", "JSON", json_strings)
    res = roundtrip_column(column)
    @test JSON3.write.(res.data) == json_strings

    @test_throws ErrorException roundtrip_column(Column("test", "JSON", ["[]"]))
    @test_throws ErrorException roundtrip_column(Column("test", "JSON", ["1"]))

end

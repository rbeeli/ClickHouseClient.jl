# Type mapping

The client writes native ClickHouse binary column formats. The Julia value type
must be compatible with the ClickHouse column type in the table.

## Common mappings

| ClickHouse type | Julia input | Julia output |
| --- | --- | --- |
| `UInt8` ... `UInt256` | matching unsigned integer vectors | matching unsigned integer vectors |
| `Int8` ... `Int256` | matching signed integer vectors | matching signed integer vectors |
| `Float32`, `Float64`, `BFloat16` | matching float vectors | same |
| `String` | `Vector{String}` | `Vector{String}` |
| `FixedString(N)` | `Vector{String}` with at most `N` bytes | NUL-padded `String` values |
| `Date`, `Date32` | `Vector{Date}` | `Vector{Date}` |
| `Time` | `Vector{ClickHouseTime}` or exact `Vector{Time}` | `Vector{ClickHouseTime}` |
| `Time64(P)` | `Vector{ClickHouseTime64{P}}` or exact `Vector{Time}` | `Vector{ClickHouseTime64{P}}` |
| `DateTime` | whole-second `Vector{DateTime}` or `Vector{ZonedDateTime}` | `Vector{DateTime}` or `Vector{ZonedDateTime}` for timezone-qualified columns |
| `DateTime64(P)` | `Vector{DateTime}`, `Vector{DateTime64{P}}`, `Vector{ZonedDateTime}`, `Vector{ClickHouseZonedDateTime64{P}}`, or raw integer ticks | `Vector{DateTime64{P}}`, `Vector{ZonedDateTime}` for timezone-qualified columns with `P <= 3`, or `Vector{ClickHouseZonedDateTime64{P}}` for timezone-qualified columns with `P > 3` |
| `Nullable(T)` | `Vector{Union{T, Missing}}` or compatible vector with `missing` | vector containing `missing` |
| `LowCardinality(String)` | `Vector{String}` or `CategoricalVector{String}` | `CategoricalVector{String}` |
| `Enum8`, `Enum16` | `Vector{String}` or `CategoricalVector{String}` | `CategoricalVector{String}` |
| `UUID` | `Vector{UUID}` | `Vector{UUID}` |
| `IPv4`, `IPv6` | `Vector{IPv4}`, `Vector{IPv6}` | same |
| `Decimal32/64/128/256`, `Decimal(P)`, `Decimal(P,S)` | DecFP decimal vectors, exact `ClickHouseDecimal*{S}` vectors, or raw scaled integers | exact `ClickHouseDecimal*{S}` vectors |
| `Array(T)` | vector of vectors | vector of vectors |
| `Tuple(...)` | vector of tuples | vector of tuples |
| `Map(K,V)` | vector of dictionaries or vectors of pairs/2-tuples | vector of pair vectors |
| `Variant(...)` | `ClickHouseVariant{I}` values, unambiguous raw values, or `missing` | `ClickHouseVariant{I}` values or `missing` |
| `Dynamic` | supported scalar values or `missing` | `ClickHouseDynamic` values or `missing` |
| `JSON` | JSON object strings or JSON3-compatible objects | `Vector{JSON3.Object}` |

## UInt8, UInt16, UInt32, UInt64, UInt128, and UInt256

Use the matching Julia unsigned integer width. The 128-bit and 256-bit widths
come from BitIntegers.jl.

```julia
using BitIntegers

insert(sock, "events", [Dict(
    :u8 => UInt8[0, typemax(UInt8)],
    :u64 => UInt64[0, typemax(UInt64)],
    :u256 => UInt256[0, typemax(UInt256)],
)])
```

## Int8, Int16, Int32, Int64, Int128, and Int256

Use the matching Julia signed integer width. Smaller integer vectors can be
converted for wider ClickHouse columns when the conversion is exact.

```julia
using BitIntegers

insert(sock, "events", [Dict(
    :i8 => Int8[typemin(Int8), 0, typemax(Int8)],
    :i64 => Int64[-1, 0, 1],
    :i256 => Int256[-1, 0, 1],
)])
```

## Float32, Float64, and BFloat16

`Float32`, `Float64`, and `BFloat16` are written in native binary form. `NaN`,
infinities, and signed zero are preserved by the column encoder.

```julia
using BFloat16s

insert(sock, "measurements", [Dict(
    :x32 => Float32[-Inf32, -0.0f0, 0.0f0, NaN32],
    :x64 => Float64[-Inf, -0.0, 0.0, NaN],
    :xb16 => BFloat16.(Float32[-1.5, 0, 1.5]),
)])
```

## Bool

ClickHouse `Bool` is encoded as `UInt8` on the wire and exposed as
`Vector{Bool}`.

```julia
insert(sock, "flags", [Dict(
    :active => Bool[false, true, false],
)])
```

## String

`String` columns accept `Vector{String}`. Values are length-prefixed byte
strings, so empty strings, UTF-8 text, and embedded NUL bytes are preserved.

```julia
insert(sock, "payloads", [Dict(
    :body => ["", "unicode é", "has\0nul"],
)])
```

## Date and Date32

`Date` is stored as ClickHouse `UInt16` days since `1970-01-01`. ClickHouse's
classic `Date` range is `1970-01-01` through `2149-06-06`.

`Date32` uses signed days and supports `1900-01-01` through `2299-12-31`.
Values outside the ClickHouse-supported range throw before encoding.

```julia
using Dates

insert(sock, "calendar", [Dict(
    :d => Date[Date(1970, 1, 1), Date(2149, 6, 6)],
    :d32 => Date[Date(1900, 1, 1), Date(2299, 12, 31)],
)])
```

## Time and Time64

`Time` stores signed whole-second ticks. Use `ClickHouseTime` when you already
have raw ClickHouse second ticks, including negative or multi-day values, or
`Dates.Time` values that have no subsecond component.

`Time64(P)` stores signed ticks at precision `P`. Use `ClickHouseTime64{P}` for
raw exact ticks, including negative or multi-day values, or exact `Dates.Time`
values.

```julia
using Dates

insert(sock, "clock_samples", [Dict(
    :t => ClickHouseTime[ClickHouseTime(0), ClickHouseTime(3661)],
    :t64 => ClickHouseTime64{6}[ClickHouseTime64{6}(0), ClickHouseTime64{6}(1_234_567)],
)])
```

## DateTime and DateTime64

`DateTime` is whole-second precision. A Julia `DateTime` with milliseconds
cannot be written to a ClickHouse `DateTime` column because that would lose
data.

ClickHouse stores `DateTime64(P)` as signed integer ticks at precision `P`.
`DateTime64{P}` preserves those ticks exactly. Inputs are checked against
ClickHouse's supported range. At nanosecond precision, the upper bound is also
limited by the signed 64-bit tick representation.

Reads from `DateTime('Zone')` return `ZonedDateTime` values. Reads from
`DateTime64(P, 'Zone')` return `ZonedDateTime` when `P <= 3`, because Julia
`DateTime` and TimeZones.jl preserve millisecond precision. For `P > 3`, reads
return `ClickHouseZonedDateTime64{P}`, which keeps exact UTC ticks plus the
ClickHouse timezone metadata.

See [Date/time and time zones](datetime_timezones.md) for precision, timezone,
and insertion examples.

```julia
using Dates

insert(sock, "events", [Dict(
    :created_at => DateTime[DateTime(2024, 1, 1, 12, 0, 0)],
    :created_at64 => DateTime64{6}[DateTime64{6}(1_704_110_400_123_456)],
)])
```

## FixedString

`FixedString(N)` is byte-counted, not character-counted. Short values are padded
with NUL bytes. Overlong values throw before the column is written.

```julia
insert(sock, "sessions", [Dict(
    :session_key => ["abc", "0123456789abcdef"],
)])
```

When reading `FixedString(5)`, `"abc"` comes back as `"abc\0\0"` because that
is the ClickHouse native value.

## Nullable columns

Use a vector whose element type permits `missing`:

```julia
user_ids = Union{UInt64, Missing}[1001, missing, 1002]
```

Avoid `Any` vectors for production loaders. Concrete or small-union vectors
give the encoder better type information and avoid unnecessary dynamic dispatch.

```julia
insert(sock, "events", [Dict(
    :user_id => Union{UInt64, Missing}[1001, missing, 1002],
)])
```

## LowCardinality

`LowCardinality(T)` reads as a `CategoricalVector`. Writes accept either a
plain vector or a categorical vector.

```julia
using CategoricalArrays

insert(sock, "events", [Dict(
    :country => CategoricalVector(["CH", "US", "CH"]),
)])
```

## Enum8 and Enum16

Enum columns read as `CategoricalVector{String}` and write string labels. Labels
must be declared in the ClickHouse type string.

```julia
insert(sock, "events", [Dict(
    :status => ["new", "done", "new"],
)])
# table column type: Enum8('new' = 1, 'done' = 2)
```

## UUID

`UUID` columns use `UUIDs.UUID` values.

```julia
using UUIDs

insert(sock, "events", [Dict(
    :id => UUID[uuid4(), uuid4()],
)])
```

## IPv4 and IPv6

IP columns use `Sockets.IPv4` and `Sockets.IPv6`.

```julia
using Sockets

insert(sock, "hosts", [Dict(
    :ip4 => IPv4[IPv4("192.0.2.1")],
    :ip6 => IPv6[IPv6("2001:db8::1")],
)])
```

## Array

`Array(T)` uses nested Julia vectors. Empty inner arrays are preserved.

```julia
insert(sock, "events", [Dict(
    :tags => Vector{String}[["red", "blue"], String[]],
    :scores => Vector{Int64}[[1, 2], Int64[]],
)])
```

## Tuple

`Tuple(...)` uses Julia tuples with the same arity and compatible element
types.

```julia
insert(sock, "events", [Dict(
    :point => Tuple{Int64, String}[(1, "one"), (2, "two")],
)])
```

## Map

ClickHouse stores `Map(K,V)` as an array of key-value tuples. Reads return pair
vectors so key order and duplicate keys are preserved:

```julia
Vector{Pair{String, UInt64}}[
    ["a" => 1, "b" => 2],
]
```

Writes accept dictionaries for convenience, or vectors of pairs/2-tuples when
order matters.

```julia
insert(sock, "events", [Dict(
    :attributes => Vector{Pair{String, UInt64}}[
        ["a" => 1, "a" => 2],
        Pair{String, UInt64}[],
    ],
)])
```

## Nothing

`Nothing` represents ClickHouse's null-only type. Top-level writes are usually
through `Nullable(Nothing)` or nested forms such as `Array(Nothing)`.

```julia
insert(sock, "events", [Dict(
    :always_null => [missing, missing],
    :empty_lists => [Missing[], Missing[]],
)])
# table columns: Nullable(Nothing), Array(Nothing)
```

## SimpleAggregateFunction

`SimpleAggregateFunction(name, T)` uses the same Julia values as its nested
type `T`; the aggregate function name is part of the ClickHouse schema, not the
Julia representation.

```julia
insert(sock, "rollups", [Dict(
    :total => Int64[10, 20, 30],
)])
# table column type: SimpleAggregateFunction(sum, Int64)
```

## Decimal32, Decimal64, Decimal128, Decimal256, and Decimal(P,S)

Decimal columns read as exact scaled-integer wrapper values:

```julia
ClickHouseDecimal32{4}(123_456)   # 12.3456 in Decimal32(4)
ClickHouseDecimal64{4}(123_456)
ClickHouseDecimal128{4}(123_456)
ClickHouseDecimal256{4}(123_456)
```

The type parameter is the ClickHouse scale, and `value` is the stored scaled
integer. This preserves ClickHouse's full decimal range, including values that
cannot round-trip through DecFP exactly.

Decimal writes validate both scale and declared precision. For `Decimal(P,S)`,
`S` must be between `0` and `P`, and raw scaled integer values must fit the
declared precision, not just the underlying storage width.

DecFP values remain supported for writes:

```julia
using DecFP

insert(sock, "payments", [Dict(
    :amount => Dec64["12.3400", "99.9900"],
)])
```

Choose a DecFP type that matches the ClickHouse precision. For example,
`Decimal(18, 4)` can be written from `Dec64`, but reads return
`ClickHouseDecimal64{4}`.

## Variant

`Variant(T1, T2, ...)` reads as `ClickHouseVariant{I}` wrappers, where `I` is
the 1-based alternative index. Writes accept wrappers, unambiguous raw values,
or `missing`.

```julia
values = Union{
    Missing,
    ClickHouseVariant{1, Int32},
    ClickHouseVariant{2, String},
}[
    ClickHouseVariant{1}(Int32(42)),
    ClickHouseVariant{2}("forty-two"),
    missing,
]

insert(sock, "events", [Dict(:value => values)])
```

If a raw value can match more than one alternative, wrap it with
`ClickHouseVariant{I}`.

## Dynamic

`Dynamic` currently writes values through ClickHouse's shared-variant native
serialization. It supports common scalar values, dates/times, decimals, strings,
and `missing`. Parameterized `Dynamic(...)` forms are not supported.

```julia
insert(sock, "events", [Dict(
    :value => Any[
        Int32(42),
        "forty-two",
        Date(2024, 1, 1),
        ClickHouseDecimal64{2}(1234),
        missing,
    ],
)])
```

Reads return `ClickHouseDynamic(type_name, value)` wrappers or `missing`.

## JSON

`JSON` uses ClickHouse's native JSON-as-string serialization and accepts JSON
objects. Arrays, scalar JSON values, and parameterized `JSON(...)` forms are
rejected because this client only supports the JSON-as-string native path.

```julia
using JSON3

insert(sock, "events", [Dict(
    :metadata => [
        JSON3.read("""{"a":1}"""),
        """{"b":"x"}""",
    ],
)])
```

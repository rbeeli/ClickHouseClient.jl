# Pitfalls and gotchas

## Choose the right insert API

`insert` is the native columnar API. It accepts one dictionary per block, and
each value is a full column vector.

```julia
# One block with three rows.
insert(sock, "t", [Dict(
    :id => UInt64[1, 2, 3],
    :name => ["a", "b", "c"],
)])
```

`insert_records` is the row-oriented API. It accepts an iterable of row
dictionaries, named tuples, or Tables.jl rows and batches them into columnar
blocks.

```julia
insert_records(sock, "t", [
    Dict(:id => UInt64(1), :name => "a"),
    Dict(:id => UInt64(2), :name => "b"),
    Dict(:id => UInt64(3), :name => "c"),
])
```

## Column names must match exactly

The server sends a sample block for the insert query. The client checks your
columnar block keys against that sample. Extra, missing, or misspelled columns
throw before the block is encoded.

`insert_records` optimizes for ingestion throughput and does not check every
record's full key set by default. It reads the destination columns from each
record, so missing required keys fail when accessed and extra keys are ignored.
Use `validate_records=true` when you need strict per-record column-set checks.

## Use concrete vectors

Avoid `Vector{Any}` in loaders. Prefer concrete vectors:

```julia
ids = UInt64[]
names = String[]
maybe_user = Union{UInt64, Missing}[]
```

This is more efficient and prevents accidental type widening.

## `DateTime` has second precision

ClickHouse `DateTime` stores whole seconds. Use `DateTime64(P)` for subsecond
data.

## `DateTime64` is exact

`DateTime64{9}` can represent nanosecond ticks that Julia `DateTime` cannot.
Keep those values as `DateTime64{9}` unless you know millisecond conversion is
exact.

Timezone-qualified `DateTime64(P, 'Zone')` columns return TimeZones.jl
`ZonedDateTime` only for `P <= 3`. Higher precision values return
`ClickHouseZonedDateTime64{P}` to keep the timezone metadata without silently
losing microseconds or nanoseconds.

See [Date/time and time zones](datetime_timezones.md) for examples.

## `FixedString(N)` counts bytes

`FixedString(16)` means exactly 16 bytes on the wire. Multibyte UTF-8 characters
consume more than one byte. Short values are NUL padded.

## Server errors close the connection

The client closes the socket when an operation throws. Reconnect before retrying
or sending another query.

## Insert table names are identifiers

`insert(sock, table, blocks)`, `insert_records(sock, table, records)`, and
`insert_table(sock, table, source)` treat `table` as an identifier, not a SQL
fragment. Strings may be `table` or `database.table`; each identifier part is
quoted by the client. Use `TableRef(database, table)` when constructing names
programmatically.

```julia
insert(sock, "analytics.events", blocks)
insert(sock, TableRef("analytics", "weird-table-name"), blocks)
```

## Keep blocks reasonably large

Very small blocks spend most of their time in protocol overhead. For ingestion,
batch thousands to hundreds of thousands of rows per block depending on row
width.

## LowCardinality is dictionary encoded by ClickHouse

You can insert plain `Vector{String}` values into `LowCardinality(String)`.
When reading, the client returns categorical data. This is normal and preserves
the dictionary shape of the ClickHouse type.

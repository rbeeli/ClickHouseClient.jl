# ClickHouseClient.jl

ClickHouseClient.jl is a pure Julia client for ClickHouse using the native TCP
protocol. It is intended for jobs that need typed columnar inserts, efficient
block reads, compression, and direct access to ClickHouse wire formats without
going through HTTP or CSV serialization.

The API is deliberately small:

- `connect` opens a native TCP session.
- `execute` runs DDL or commands that do not return rows.
- `insert` sends one or more columnar blocks into a table.
- `insert_records` batches row dictionaries into columnar blocks and inserts
  them.
- `query`, `select_df`, `select_channel`, and `select_callback` read ordered
  query results in the shape that fits your workflow.

## Minimal example

```julia
using ClickHouseClient
using DataFrames
using Dates

sock = connect("localhost"; username="default", compression=COMPRESSION_LZ4)

execute(sock, """
    CREATE TABLE IF NOT EXISTS metrics
    (
        ts DateTime64(6, 'UTC'),
        host LowCardinality(String),
        metric LowCardinality(String),
        value Float64
    )
    ENGINE = MergeTree
    ORDER BY (host, metric, ts)
""")

insert(sock, "metrics", [Dict(
    :ts => DateTime64.(DateTime[
        DateTime(2026, 1, 1, 0, 0, 0, 100),
        DateTime(2026, 1, 1, 0, 0, 1, 250),
    ], 6),
    :host => ["api-01", "api-01"],
    :metric => ["latency_ms", "latency_ms"],
    :value => [12.7, 18.4],
)])

select_df(sock, """
    SELECT host, metric, avg(value) AS avg_value
    FROM metrics
    GROUP BY host, metric
""")
```

If your data naturally arrives as row dictionaries, use `insert_records`:

```julia
insert_records(sock, "metrics", [
    Dict(:ts => DateTime(2026, 1, 1, 0, 0, 2),
         :host => "api-02",
         :metric => "latency_ms",
         :value => 21.3),
])
```

## What this client focuses on

- Native TCP protocol support, including LZ4, LZ4HC, and ZSTD-compressed blocks.
- Column-oriented inserts that match ClickHouse's expected binary formats, plus
  row-record batching when input data is naturally row-shaped.
- Exact handling of primitive integers through 256 bits, `BFloat16`,
  `FixedString`, `Nullable`, `LowCardinality`, `Date`, `Date32`, `Time`,
  `Time64`, `DateTime`, `DateTime64`, `Decimal`, `UUID`, `IPv4`, `IPv6`,
  arrays, tuples, `Variant`, `Dynamic`, and `JSON`.
- Streaming reads through callbacks or channels so large result sets do not
  need to be materialized at once.
- Optional DataFrames.jl integration through `select_df`; load DataFrames only
  when you want DataFrame materialization.
- Conservative connection handling after server errors so a partially consumed
  protocol stream is not reused.

## Documentation map

- [Getting started](getting_started.md): start ClickHouse and run a first
  ingest/query loop.
- [Basic setup](basic_setup.md): the usual pieces of an application using this
  client.
- [Connections](connections.md): connection settings, compression, and socket
  lifecycle.
- [Inserts and queries](inserts_and_queries.md): block inserts, result shapes,
  streaming reads, and progress callbacks.
- [DataFrames integration](dataframes.md): optional DataFrames.jl query and
  insert workflows.
- [Type mapping](type_mapping.md): how Julia values map to ClickHouse column
  types.
- [Date/time and time zones](datetime_timezones.md): precision, timezone, and
  timestamp insertion rules.
- [Pitfalls and gotchas](pitfalls.md): common mistakes and how to avoid them.
- Examples: end-to-end snippets for ingest, streaming, precision handling, and
  batch loading.

## Supported ClickHouse types

- `String`, `FixedString(N)`
- `Float32`, `Float64`, `BFloat16`
- `Int8`, `Int16`, `Int32`, `Int64`, `Int128`, `Int256`
- `UInt8`, `UInt16`, `UInt32`, `UInt64`, `UInt128`, `UInt256`
- `Date`, `Date32`, `Time`, `Time64`, `DateTime`, `DateTime64`
- `Enum8`, `Enum16`
- `UUID`
- `Tuple`
- `LowCardinality(T)`
- `Nullable(T)`
- `Array(T)`
- `Nothing`
- `SimpleAggregateFunction`
- `IPv4`, `IPv6`
- `Decimal`, `Decimal32`, `Decimal64`, `Decimal128`, `Decimal256`
- `Variant`
- `Dynamic`
- `JSON`

## Credits

Several column implementations were informed by the Python
[`clickhouse-driver`](https://github.com/mymarilyn/clickhouse-driver) and by
ClickHouse's native protocol behavior.

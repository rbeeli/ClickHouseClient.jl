# Basic setup

A production script using ClickHouseClient.jl usually has five pieces.

## 1. Connection configuration

Create one `ClickHouseSock` per concurrent task. A socket is not a connection
pool; it is a single native protocol stream.

```julia
using ClickHouseClient

sock = connect(
    "clickhouse.internal";
    database="analytics",
    username="loader",
    password=get(ENV, "CLICKHOUSE_PASSWORD", ""),
    compression=COMPRESSION_LZ4,
)
```

## 2. Explicit schema

Keep table creation next to the code that writes the table. ClickHouse's native
insert protocol asks the server for a sample block and then encodes your Julia
columns using that schema.

```julia
execute(sock, """
    CREATE TABLE IF NOT EXISTS page_views
    (
        ts DateTime64(6, 'UTC'),
        tenant LowCardinality(String),
        user_id Nullable(UInt64),
        path String,
        status UInt16,
        duration_ms UInt32
    )
    ENGINE = MergeTree
    PARTITION BY toYYYYMM(ts)
    ORDER BY (tenant, ts)
""")
```

## 3. Inserts

Use `insert` when your data is already columnar. It takes an iterable of block
dictionaries. Each block is a mapping from `Symbol` column names to vectors.
All vectors in a block must have the same length, and the set of names must
match the table columns exactly.

```julia
block = Dict(
    :ts => DateTime64.(timestamps, 6),
    :tenant => tenant_strings,
    :user_id => Union{UInt64, Missing}[1001, missing, 1002],
    :path => paths,
    :status => UInt16[200, 503, 200],
    :duration_ms => UInt32[12, 431, 19],
)

insert(sock, "page_views", [block])
```

Use `insert_records` when your data arrives as records. Each record is a
dictionary from column name to scalar value. Records are batched into native
columnar blocks before they are sent to ClickHouse.

```julia
insert_records(sock, "page_views", [
    Dict(
        :ts => DateTime(2026, 1, 1, 12),
        :tenant => "acme",
        :user_id => UInt64(1001),
        :path => "/checkout",
        :status => UInt16(200),
        :duration_ms => UInt32(12),
    ),
    Dict(
        :ts => DateTime(2026, 1, 1, 12, 0, 1),
        :tenant => "acme",
        :user_id => missing,
        :path => "/checkout",
        :status => UInt16(503),
        :duration_ms => UInt32(431),
    ),
]; block_size=50_000)
```

## 4. Query shape

Choose the reader by result size:

- `query`: returns one ordered `QueryResult` for convenient small and medium
  queries.
- `select_df`: converts the same ordered result to a `DataFrame` when
  DataFrames.jl is loaded.
- `select_callback`: streams each non-empty `QueryBlock` into a callback.
- `select_channel`: exposes streamed `QueryBlock` values through a Julia
  `Channel`.

## 5. Error and cleanup policy

Server-side errors close the socket. Reconnect before retrying:

```julia
try
    insert(sock, "page_views", [block])
catch err
    sock = connect("clickhouse.internal"; username="loader", compression=COMPRESSION_LZ4)
    rethrow(err)
end
```

For scripts, close the socket when finished:

```julia
close(sock)
```

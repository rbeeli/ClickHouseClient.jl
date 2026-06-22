# Inserts and queries

ClickHouse's native protocol is block-oriented. This client exposes that model
directly instead of hiding it behind row-by-row APIs.

## Executing commands

Use `execute` for DDL and commands that return no rows:

```julia
execute(sock, "DROP TABLE IF EXISTS scratch")
execute(sock, """
    CREATE TABLE scratch
    (
        id UInt64,
        value String
    )
    ENGINE = Memory
""")
```

## Inserting columnar blocks

Each insert block is a dictionary from column name to column vector. The client
uses the destination table's sample block to write columns in server order, so
dictionary iteration order does not affect the native block layout.

```julia
insert(sock, "scratch", [Dict(
    :id => UInt64[1, 2, 3],
    :value => ["a", "b", "c"],
)])
```

The iterable can contain many blocks:

```julia
blocks = (
    Dict(:id => UInt64[i:i+999], :value => string.("row-", i:i+999))
    for i in 1:1000:100_000
)

insert(sock, "scratch", blocks)
```

All columns in a block must have the same length. The set of keys must match
the server's sample block exactly. Mismatches throw `ArgumentError` or
`DimensionMismatch` before data is sent.

The `table` argument is an identifier, not a SQL fragment. Pass `"table"`,
`"database.table"`, or `TableRef(database, table)`.

## Inserting row records

Use `insert_records` when the input is row-shaped. Each record is a dictionary
from column name to scalar value. Keys can be `Symbol`s or strings.

```julia
records = [
    Dict(:id => UInt64(1), :value => "a"),
    Dict("id" => UInt64(2), "value" => "b"),
    Dict(:id => UInt64(3), :value => "c"),
]

insert_records(sock, "scratch", records; block_size=10_000)
```

Internally, `insert_records` batches records into the same columnar block shape
that `insert` accepts. This keeps the wire format native while giving you a
clear row-oriented API for JSON-like data, message queues, and application
event records.

For throughput, record inserts do not validate every record's full key set by
default. The encoder reads the destination columns from each record; missing
required keys still fail, while extra keys are ignored. Pass
`validate_records=true` to reject extra or missing keys with a per-row column
set check:

```julia
insert_records(sock, "scratch", records; validate_records=true)
```

## Query into a dictionary

`query` materializes all data blocks into one ordered `QueryResult`:

```julia
result = query(sock, "SELECT id, value FROM scratch ORDER BY id LIMIT 3")

ids = result[:id]
values = result[:value]
names = columnnames(result)
stats = result.stats
```

`QueryResult` preserves the server column order, supports `result[:name]` and
integer column access, carries the ClickHouse type strings in `columntypes`, and
implements the Tables.jl column interface. Use `result_dict(result)` when a
plain `Dict{Symbol, AbstractVector}` is required.

Queries that return `WITH TOTALS` or extremes keep those blocks separate from
ordinary rows:

```julia
result = query(sock, "SELECT value, count() FROM scratch GROUP BY value WITH TOTALS")

result[:value]      # ordinary data rows
result.totals       # QueryBlock or nothing
result.extremes     # QueryBlock or nothing
```

## Query into a DataFrame

```julia
using DataFrames

df = select_df(sock, "SELECT id, value FROM scratch ORDER BY id")
```

`select_df` is provided by the optional DataFrames.jl extension. It uses the
same ordered result as `query`, then passes it to DataFrames.jl through
Tables.jl.

## Insert a Tables.jl source

Use `insert_table` for Tables.jl-compatible sources such as a `DataFrame`,
`Arrow.Table`, named tuple of columns, or an iterable of named tuple rows:

```julia
using DataFrames

df = DataFrame(
    id = UInt64[1, 2, 3],
    value = ["a", "b", "c"],
)

insert_table(sock, "scratch", df; block_size = 100_000)
```

Column-access tables are sliced into native blocks without first converting the
whole source with `Tables.columntable`. Row-access tables are streamed through
the same batching path as `insert_records`, so `block_size` bounds the number of
rows held by the client for those sources.

For row-access Tables.jl sources, `insert_table(...; validate_records=true)`
enables the same strict per-row column-set validation as `insert_records`.

The table schema still comes from ClickHouse's insert sample block, so Julia
column names must match the destination columns and values must be compatible
with the ClickHouse types.

## Per-query options

All query entry points accept `options=QueryOptions(...)`: `execute`,
`insert`, `insert_records`, `insert_table`, `query`, `select_df`,
`select_channel`, and `select_callback`.

Use it for query ids, settings, quota keys, query stages, OpenTelemetry trace
context, and per-query compression:

```julia
options = QueryOptions(
    query_id = "daily-rollup-2026-06-21",
    quota_key = "batch-jobs",
    settings = (
        max_threads = 4,
        max_execution_time = 30,
    ),
    compression = COMPRESSION_LZ4,
)

select_df(sock, """
    SELECT value, count() AS rows
    FROM scratch
    GROUP BY value
"""; options)
```

`settings` can be a `Dict`, named tuple, vector of pairs, tuple of pairs, or
`QuerySetting` values when you need protocol flags:

```julia
options = QueryOptions(settings = Dict(
    "send_logs_level" => "information",
    "send_profile_events" => 1,
))
```

Attach OpenTelemetry context when a query should join an existing trace:

```julia
options = QueryOptions(
    opentelemetry = OpenTelemetryContext(
        "00112233445566778899aabbccddeeff",
        "0102030405060708";
        trace_state = "vendor=value",
        trace_flags = 1,
    ),
)
```

Use `stage=QUERY_STAGE_FETCH_COLUMNS` when you only want ClickHouse to return
the result schema.

## Query parameters

ClickHouse query parameters are referenced in SQL as `{name:Type}` and supplied
through `QueryOptions(parameters=...)`.

```julia
result = query(sock, """
    SELECT id, value
    FROM scratch
    WHERE id >= {min_id:UInt64}
      AND value != {skip_value:String}
    ORDER BY id
"""; options = QueryOptions(parameters = (
    min_id = 10,
    skip_value = "ignore-me",
)))
```

Parameter values are sent separately from the SQL text and ClickHouse parses
each value using the type declared in the placeholder.

## External temporary tables

Use `ExternalTable` to send small in-memory lookup tables with a query:

```julia
ids = ExternalTable("wanted_ids", [
    Column("id", "UInt64", UInt64[1, 3, 5]),
])

result = query(sock, """
    SELECT scratch.id, scratch.value
    FROM scratch
    INNER JOIN wanted_ids USING id
    ORDER BY id
"""; options = QueryOptions(external_tables = [ids]))
```

Each `Column` needs the temporary table column name, ClickHouse type string,
and Julia vector. The external table exists only for that query.

## Stream with a callback

Use `select_callback` for large results. The callback receives each non-empty
ClickHouse block as an ordered `QueryBlock`.

```julia
rows = 0
sum_ids = UInt128(0)

select_callback(sock, "SELECT id FROM scratch") do block
    ids = block[:id]
    rows += length(ids)
    sum_ids += sum(UInt128, ids)
end
```

## Stream through a channel

```julia
ch = select_channel(sock, "SELECT id, value FROM scratch")

for block in ch
    @info "received block" rows=length(block[:id])
end
```

Channels are useful when another task consumes blocks asynchronously.

If you stop consuming before the query finishes, call `close(ch)`. Closing the
channel cancels the query best-effort and closes the connection because the
native result stream is no longer synchronized.

## Query stats

`query` returns accumulated query stats in `result.stats`. For `execute`,
`insert`, `insert_records`, `insert_table`, and callback/channel workflows, pass
a `QueryStats()` value with `stats=...`:

```julia
stats = QueryStats()
execute(sock, "OPTIMIZE TABLE scratch"; stats)

@info "query progress" rows=stats.rows bytes=stats.bytes elapsed_ns=stats.elapsed_ns
```

Progress counters are accumulated from ClickHouse progress packets. Server log
and profile-event blocks are stored on `stats.log_blocks` and
`stats.profile_event_blocks`.

## Progress packets

ClickHouse can send `Progress` packets while a query is running. The client
always handles those packets internally so the protocol stays synchronized.

If you want progress data, pass a callback:

```julia
select_callback(
    block -> nothing,
    sock,
    "SELECT count() FROM scratch";
    progress_callback = p -> @info(
        "progress",
        rows=UInt64(p.rows),
        bytes=UInt64(p.bytes),
        total_rows=UInt64(p.total_rows),
    ),
)
```

No progress UI package is required by the client. The callback receives the raw
`ServerProgress` packet.

## Server logs and profile events

ClickHouse can send native log and profile-event packets while a query runs.
Enable the corresponding settings and pass callbacks:

```julia
logs = Block[]
profile_events = Block[]

select_callback(
    block -> nothing,
    sock,
    "SELECT count() FROM scratch";
    options = QueryOptions(settings = (
        send_logs_level = "information",
        send_profile_events = 1,
    )),
    log_callback = block -> push!(logs, block),
    profile_events_callback = block -> push!(profile_events, block),
)
```

The callbacks receive raw `Block` values because ClickHouse sends logs and
profile events as native blocks.

## Cancellation

Use `cancel(sock)` from another task to request cancellation of the query
currently running on that socket:

```julia
task = @async query(sock, "SELECT sleepEachRow(0.1) FROM numbers(1000)")

sleep(1)
cancel(sock)

try
    fetch(task)
catch err
    @info "query cancelled" err
end
```

After a cancelled query throws, reconnect before reusing the socket. The client
closes sockets after request errors to avoid reusing a partially consumed
native protocol stream.

## Table status

`table_status` asks ClickHouse for replication and read-only status over the
native protocol:

```julia
status = table_status(sock, [
    TableRef("default", "scratch"),
])

scratch_status = status[TableRef("default", "scratch")]
scratch_status.is_replicated
scratch_status.absolute_delay
scratch_status.is_readonly
```

Passing a plain table name uses the socket's default database:

```julia
status = table_status(sock, "scratch")
```

# DataFrames integration

DataFrames.jl support is optional. Load DataFrames when you want
`select_df`; the base ClickHouseClient package does not depend on DataFrames.

```julia
using ClickHouseClient
using DataFrames
using Dates

sock = connect("localhost"; username="default", compression=COMPRESSION_LZ4)
```

## Query into a DataFrame

`select_df` runs the same native query path as `query`, then materializes the
ordered result through Tables.jl:

```julia
df = select_df(sock, """
    SELECT
        toDate(ts) AS day,
        service,
        count() AS events,
        quantile(0.95)(latency_ms) AS p95_latency_ms
    FROM app_events
    WHERE ts >= now() - INTERVAL 1 DAY
    GROUP BY day, service
    ORDER BY day, service
""")
```

For totals or extremes, use `query` so those native packets stay separate from
ordinary rows:

```julia
result = query(sock, """
    SELECT service, count() AS events
    FROM app_events
    GROUP BY service
    WITH TOTALS
""")

rows = DataFrame(result; copycols=false)
totals = result.totals === nothing ? nothing :
    DataFrame(result.totals; copycols=false)
```

## Insert a DataFrame

`insert_table` accepts any column-access Tables.jl source. DataFrame columns are
sliced into native ClickHouse blocks without converting the whole table to row
objects.

```julia
df = DataFrame(
    ts = DateTime64.(DateTime[
        DateTime(2026, 1, 1, 12, 0, 0, 100),
        DateTime(2026, 1, 1, 12, 0, 1, 250),
    ], 6),
    service = ["api", "worker"],
    level = ["info", "warn"],
    latency_ms = UInt32[18, 401],
)

insert_table(sock, "app_events", df; block_size=100_000)
```

Column names must match the ClickHouse insert sample block. Values are encoded
using the same type rules as `insert` and `insert_records`, including strict
checks for `DateTime64` precision, `Nullable` values, decimal scale, and
`FixedString` byte length.

## Avoiding name conflicts

DataFrames exports its own `select` transformation function. ClickHouseClient's
exported materialized query API is therefore named `query`. The lower-level
`ClickHouseClient.select` function remains available as a qualified alias, but
new code should prefer `query`.

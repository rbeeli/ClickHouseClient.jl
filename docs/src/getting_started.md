# Getting started

This page gets from a clean checkout to a working ClickHouse insert and query.

## Install

```julia
using Pkg
Pkg.add(url="https://github.com/rbeeli/ClickHouseClient.jl")
Pkg.add("DataFrames") # optional; needed only for select_df
```

If you are working inside this repository, use the project environment:

```bash
julia --project=.
```

## Start a local ClickHouse server

Inside the repository, the `justfile` starts the same ClickHouse server used by
the integration tests:

```bash
just start
```

When finished:

```bash
just stop
```

Equivalent Docker command:

```bash
docker run --rm -d --name clickhouseclient-dev \
  --ulimit nofile=262144:262144 \
  -e CLICKHOUSE_SKIP_USER_SETUP=1 \
  -p 9000:9000 -p 8123:8123 \
  clickhouse/clickhouse-server:25.3
```

## First connection

```julia
using ClickHouseClient

sock = connect("localhost"; username="default")
ping(sock)
```

For larger transfers, enable native block compression:

```julia
sock = connect("localhost"; username="default", compression=COMPRESSION_LZ4)
```

## Create, insert, query

```julia
using ClickHouseClient
using DataFrames
using Dates

sock = connect("localhost"; username="default", compression=COMPRESSION_LZ4)

execute(sock, """
    CREATE TABLE IF NOT EXISTS getting_started_events
    (
        ts DateTime64(6, 'UTC'),
        service LowCardinality(String),
        level LowCardinality(String),
        message String,
        latency_ms UInt32
    )
    ENGINE = MergeTree
    ORDER BY (service, ts)
""")

insert(sock, "getting_started_events", [Dict(
    :ts => DateTime64.(DateTime[
        DateTime(2026, 1, 1, 12, 0, 0, 100),
        DateTime(2026, 1, 1, 12, 0, 1, 250),
        DateTime(2026, 1, 1, 12, 0, 2, 900),
    ], 6),
    :service => ["api", "api", "worker"],
    :level => ["info", "warn", "info"],
    :message => ["accepted request", "slow upstream", "job complete"],
    :latency_ms => UInt32[18, 401, 73],
)])

select_df(sock, """
    SELECT service, count() AS events, avg(latency_ms) AS avg_latency_ms
    FROM getting_started_events
    GROUP BY service
    ORDER BY service
""")
```

## Next steps

- Read [Basic setup](basic_setup.md) for the typical structure of a small
  application.
- Read [Date/time and time zones](datetime_timezones.md) before loading
  timestamp columns with subsecond precision or timezone metadata.
- Read [Type mapping](type_mapping.md) before loading `DateTime64`, decimal,
  nullable, or fixed-width string data.
- Browse the examples for ingestion, streaming, precision, and batch loading.

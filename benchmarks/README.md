# ClickHouseClient.jl Benchmarks

This harness compares `ClickHouseClient.jl` against three mature ClickHouse
clients on local ClickHouse workloads:

- Python `clickhouse-connect`
- Go `clickhouse-go/v2`
- Rust `clickhouse`

The runner prepares one shared read table and measures these scenarios:

- `read_scan_materialize`: ordered scan and client-side materialization
- `read_group_aggregate`: grouped aggregate over the same analytics table
- `write_batch_insert`: large typed batch insert
- `write_row_records`: row-record insert path

## Setup

Start ClickHouse with the repository `justfile`:

```sh
just start
```

Install optional external client dependencies when you want comparisons beyond
the Julia client:

```sh
python3 -m venv benchmarks/.venv
benchmarks/.venv/bin/pip install -r benchmarks/clients/python/requirements.txt
```

The Go client is fetched by `go run` from `benchmarks/clients/clickhouse_go`.
The Rust client is fetched by `cargo run` from
`benchmarks/clients/rust_clickhouse`.

## Run

Run all available clients:

```sh
just bench
```

Run only the Julia client:

```sh
julia --project=. benchmarks/run.jl --clients julia
```

Useful options:

```sh
julia --project=. benchmarks/run.jl \
  --rows 100000 \
  --iterations 5 \
  --clients julia,python-connect,go,rust \
  --output benchmarks/results/latest.json
```

Set `--strict` to fail instead of skipping missing external clients.
The run also writes `benchmarks/RESULTS.md` unless `--markdown` is changed.

Connection options default to the local container ports from `just start`:
`--host localhost`, `--native-port 9000`, and `--http-port 8123`.

## Notes

These are local end-to-end client benchmarks. Results include client
serialization, deserialization, network loopback, and server execution for read
queries. Use the same ClickHouse image, row count, CPU governor, and compression
settings when comparing runs. The harness does not enable compression by
default for any client.

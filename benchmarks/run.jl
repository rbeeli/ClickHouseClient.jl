#!/usr/bin/env julia

using ClickHouseClient
using Dates
using JSON3
using Printf
using Statistics

const ROOT = dirname(@__DIR__)
const BENCH_DIR = @__DIR__
const DEFAULT_RESULTS = joinpath(BENCH_DIR, "results", "latest.json")
const DEFAULT_MARKDOWN = joinpath(BENCH_DIR, "RESULTS.md")
const READ_TABLE = "clickhouseclient_bench_events"
const WRITE_TABLE_PREFIX = "clickhouseclient_bench_write"
const COLUMNS = [
    "id",
    "ts",
    "user_id",
    "category",
    "metric",
    "country",
    "nullable_score",
    "payload",
]

function parse_args(args)
    opts = Dict(
        "host" => "localhost",
        "native-port" => "9000",
        "http-port" => "8123",
        "user" => "default",
        "password" => "",
        "database" => "",
        "rows" => "100000",
        "iterations" => "5",
        "clients" => "julia,python-connect,go,rust",
        "output" => DEFAULT_RESULTS,
        "markdown" => DEFAULT_MARKDOWN,
        "strict" => "false",
    )
    i = 1
    while i <= length(args)
        arg = args[i]
        if startswith(arg, "--")
            key = arg[3:end]
            if key == "strict"
                opts[key] = "true"
                i += 1
            else
                i == length(args) && error("missing value for $(arg)")
                opts[key] = args[i + 1]
                i += 2
            end
        else
            error("unexpected argument: $(arg)")
        end
    end
    return opts
end

function conn(opts; compression = COMPRESSION_NONE)
    return connect(
        opts["host"];
        username = opts["user"],
        password = opts["password"],
        database = opts["database"],
        compression = compression,
    )
end

function write_table_schema(table)
    return """
        CREATE TABLE IF NOT EXISTS $(table) (
            id UInt64,
            ts DateTime,
            user_id UInt64,
            category LowCardinality(String),
            metric Float64,
            country LowCardinality(String),
            nullable_score Nullable(Float64),
            payload String
        )
        ENGINE = Memory
    """
end

function setup_read_table(sock, rows)
    execute(sock, """
        CREATE TABLE IF NOT EXISTS $(READ_TABLE) (
            id UInt64,
            ts DateTime,
            user_id UInt64,
            category LowCardinality(String),
            metric Float64,
            country LowCardinality(String),
            nullable_score Nullable(Float64),
            payload String
        )
        ENGINE = MergeTree
        ORDER BY id
    """)
    execute(sock, "TRUNCATE TABLE $(READ_TABLE)")
    execute(sock, """
        INSERT INTO $(READ_TABLE)
        SELECT
            number AS id,
            toDateTime('2024-01-01 00:00:00') + toIntervalSecond(number % 86400) AS ts,
            number % 100000 AS user_id,
            concat('cat_', toString(number % 64)) AS category,
            toFloat64(number % 100000) / 100.0 AS metric,
            concat('country_', toString(number % 24)) AS country,
            if(number % 10 = 0, NULL, toFloat64(number % 10000) / 10.0) AS nullable_score,
            concat('payload-', toString(number)) AS payload
        FROM numbers($(rows))
    """)
    return nothing
end

function setup_write_table(sock, table)
    execute(sock, "DROP TABLE IF EXISTS $(table)")
    execute(sock, write_table_schema(table))
    return nothing
end

function make_columns(rows)
    base = DateTime(2024, 1, 1)
    ids = Vector{UInt64}(undef, rows)
    timestamps = Vector{DateTime}(undef, rows)
    users = Vector{UInt64}(undef, rows)
    categories = Vector{String}(undef, rows)
    metrics = Vector{Float64}(undef, rows)
    countries = Vector{String}(undef, rows)
    scores = Vector{Union{Missing, Float64}}(undef, rows)
    payloads = Vector{String}(undef, rows)

    for i in 1:rows
        n = i - 1
        ids[i] = UInt64(n)
        timestamps[i] = base + Second(n % 86400)
        users[i] = UInt64(n % 100000)
        categories[i] = "cat_$(n % 64)"
        metrics[i] = Float64(n % 100000) / 100.0
        countries[i] = "country_$(n % 24)"
        scores[i] = n % 10 == 0 ? missing : Float64(n % 10000) / 10.0
        payloads[i] = "payload-$(n)"
    end

    return Dict(
        :id => ids,
        :ts => timestamps,
        :user_id => users,
        :category => categories,
        :metric => metrics,
        :country => countries,
        :nullable_score => scores,
        :payload => payloads,
    )
end

function make_records(cols)
    rows = length(cols[:id])
    records = Vector{NamedTuple}(undef, rows)
    for i in 1:rows
        records[i] = (
            id = cols[:id][i],
            ts = cols[:ts][i],
            user_id = cols[:user_id][i],
            category = cols[:category][i],
            metric = cols[:metric][i],
            country = cols[:country][i],
            nullable_score = cols[:nullable_score][i],
            payload = cols[:payload][i],
        )
    end
    return records
end

function percentile(sorted_values, p)
    isempty(sorted_values) && return NaN
    idx = clamp(ceil(Int, p * length(sorted_values)), 1, length(sorted_values))
    return sorted_values[idx]
end

function measure(run, client, scenario, rows, iterations; setup = () -> nothing)
    times = Float64[]
    outputs = Int[]

    setup()
    run()
    for _ in 1:iterations
        setup()
        GC.gc()
        start = time_ns()
        produced = run()
        elapsed = (time_ns() - start) / 1e9
        push!(times, elapsed)
        push!(outputs, Int(produced))
    end

    sorted_times = sort(times)
    med = median(times)
    return Dict(
        "client" => client,
        "scenario" => scenario,
        "iterations" => iterations,
        "rows" => rows,
        "produced_rows" => maximum(outputs),
        "seconds" => times,
        "min_seconds" => minimum(times),
        "median_seconds" => med,
        "p95_seconds" => percentile(sorted_times, 0.95),
        "rows_per_second" => rows / med,
    )
end

function julia_results(opts, rows, iterations)
    sock = conn(opts)
    results = Dict{String, Any}[]
    write_table = "$(WRITE_TABLE_PREFIX)_julia"
    cols = make_columns(rows)
    records = make_records(cols)
    try
        setup_write_table(sock, write_table)
        push!(results, measure("ClickHouseClient.jl", "read_scan_materialize", rows, iterations) do
            result = query(sock, """
                SELECT id, ts, user_id, category, metric, country, nullable_score, payload
                FROM $(READ_TABLE)
                ORDER BY id
                LIMIT $(rows)
            """)
            nrows(result)
        end)
        push!(results, measure("ClickHouseClient.jl", "read_group_aggregate", rows, iterations) do
            result = query(sock, """
                SELECT
                    category,
                    country,
                    count() AS rows,
                    avg(metric) AS avg_metric,
                    toFloat64(quantileTDigest(0.95)(metric)) AS p95_metric
                FROM $(READ_TABLE)
                GROUP BY category, country
                ORDER BY category, country
            """)
            nrows(result)
        end)
        push!(results, measure(
            "ClickHouseClient.jl",
            "write_batch_insert",
            rows,
            iterations;
            setup = () -> execute(sock, "TRUNCATE TABLE $(write_table)"),
        ) do
            insert(sock, write_table, [cols])
            rows
        end)
        push!(results, measure(
            "ClickHouseClient.jl",
            "write_row_records",
            rows,
            iterations;
            setup = () -> execute(sock, "TRUNCATE TABLE $(write_table)"),
        ) do
            insert_records(sock, write_table, records; block_size = rows)
            rows
        end)
    finally
        execute(sock, "DROP TABLE IF EXISTS $(write_table)")
        close(sock)
    end
    return results
end

function executable(name, env_name)
    configured = get(ENV, env_name, "")
    !isempty(configured) && return configured
    return something(Sys.which(name), "")
end

function run_external(cmd; strict = false)
    try
        output = read(cmd, String)
        parsed = JSON3.read(output)
        return [Dict{String, Any}(String(k) => v for (k, v) in pairs(item)) for item in parsed]
    catch err
        strict && rethrow()
        @warn "benchmark client skipped" command = string(cmd) exception = (err, catch_backtrace())
        return Dict{String, Any}[]
    end
end

function python_results(opts, rows, iterations; strict = false)
    python = executable("python3", "PYTHON")
    isempty(python) && return strict ? error("python3 not found") : Dict{String, Any}[]
    script = joinpath(BENCH_DIR, "clients", "python", "bench_client.py")
    cmd = Cmd([
        python,
        script,
        "--host", opts["host"],
        "--native-port", opts["native-port"],
        "--http-port", opts["http-port"],
        "--user", opts["user"],
        "--password", opts["password"],
        "--database", opts["database"],
        "--read-table", READ_TABLE,
        "--write-table", "$(WRITE_TABLE_PREFIX)_python_connect",
        "--rows", string(rows),
        "--iterations", string(iterations),
    ])
    return run_external(cmd; strict = strict)
end

function rust_results(opts, rows, iterations; strict = false)
    cargo = executable("cargo", "CARGO")
    isempty(cargo) && return strict ? error("cargo not found") : Dict{String, Any}[]
    dir = joinpath(BENCH_DIR, "clients", "rust_clickhouse")
    cmd = Cmd(Cmd([
        cargo,
        "run",
        "--release",
        "--quiet",
        "--",
        "--host", opts["host"],
        "--http-port", opts["http-port"],
        "--user", opts["user"],
        "--password", opts["password"],
        "--database", opts["database"],
        "--read-table", READ_TABLE,
        "--write-table", "$(WRITE_TABLE_PREFIX)_rust",
        "--rows", string(rows),
        "--iterations", string(iterations),
    ]); dir = dir)
    return run_external(cmd; strict = strict)
end

function go_results(opts, rows, iterations; strict = false)
    go = executable("go", "GO")
    isempty(go) && return strict ? error("go not found") : Dict{String, Any}[]
    dir = joinpath(BENCH_DIR, "clients", "clickhouse_go")
    cmd = Cmd(Cmd([
        go,
        "run",
        ".",
        "--host", opts["host"],
        "--port", opts["native-port"],
        "--user", opts["user"],
        "--password", opts["password"],
        "--database", opts["database"],
        "--read-table", READ_TABLE,
        "--write-table", "$(WRITE_TABLE_PREFIX)_go",
        "--rows", string(rows),
        "--iterations", string(iterations),
    ]); dir = dir)
    return run_external(cmd; strict = strict)
end

function print_results(results)
    println()
    println("| client | scenario | rows | median s | rows/s |")
    println("| --- | --- | ---: | ---: | ---: |")
    for result in sort(results; by = r -> (String(r["scenario"]), String(r["client"])))
        @printf(
            "| %s | %s | %d | %.6f | %.0f |\n",
            result["client"],
            result["scenario"],
            result["rows"],
            result["median_seconds"],
            result["rows_per_second"],
        )
    end
end

function markdown_table(results)
    io = IOBuffer()
    println(io, "| client | scenario | rows | produced rows | median s | p95 s | rows/s |")
    println(io, "| --- | --- | ---: | ---: | ---: | ---: | ---: |")
    for result in sort(results; by = r -> (String(r["scenario"]), String(r["client"])))
        @printf(
            io,
            "| %s | %s | %d | %d | %.6f | %.6f | %.0f |\n",
            result["client"],
            result["scenario"],
            result["rows"],
            result["produced_rows"],
            result["median_seconds"],
            result["p95_seconds"],
            result["rows_per_second"],
        )
    end
    return String(take!(io))
end

function shell_quote(value)
    str = string(value)
    return "'" * replace(str, "'" => "'\"'\"'") * "'"
end

function write_markdown(path, results, opts)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, "# Benchmark Results")
        println(io)
        println(io, "Generated by `benchmarks/run.jl`.")
        println(io)
        println(io, "## Reproduce")
        println(io)
        println(io, "Start ClickHouse with:")
        println(io)
        println(io, "```sh")
        println(io, "just start")
        println(io, "```")
        println(io)
        println(io, "Run the benchmark with normalized options:")
        println(io)
        println(io, "```sh")
        println(io, "julia --project=. benchmarks/run.jl \\")
        println(io, "  --host $(shell_quote(opts["host"])) \\")
        println(io, "  --native-port $(shell_quote(opts["native-port"])) \\")
        println(io, "  --http-port $(shell_quote(opts["http-port"])) \\")
        println(io, "  --user $(shell_quote(opts["user"])) \\")
        println(io, "  --database $(shell_quote(opts["database"])) \\")
        println(io, "  --rows $(shell_quote(opts["rows"])) \\")
        println(io, "  --iterations $(shell_quote(opts["iterations"])) \\")
        println(io, "  --clients $(shell_quote(opts["clients"])) \\")
        println(io, "  --output $(shell_quote(opts["output"])) \\")
        println(io, "  --markdown $(shell_quote(opts["markdown"]))")
        println(io, "```")
        println(io)
        println(io, "Passwords are intentionally omitted from this generated command.")
        println(io)
        println(io, "## Workloads")
        println(io)
        println(io, "- `read_scan_materialize`: ordered scan and client-side materialization.")
        println(io, "- `read_group_aggregate`: grouped aggregate over low-cardinality dimensions.")
        println(io, "- `write_batch_insert`: typed batch insert into an in-memory table.")
        println(io, "- `write_row_records`: row-record insert path into an in-memory table.")
        println(io)
        println(io, "## Results")
        println(io)
        print(io, markdown_table(results))
    end
end

function main(args)
    opts = parse_args(args)
    rows = parse(Int, opts["rows"])
    iterations = parse(Int, opts["iterations"])
    clients = Set(strip.(split(opts["clients"], ",")))
    strict = lowercase(opts["strict"]) == "true"

    sock = conn(opts)
    try
        setup_read_table(sock, rows)
    finally
        close(sock)
    end

    results = Dict{String, Any}[]
    "julia" in clients && append!(results, julia_results(opts, rows, iterations))
    "python-connect" in clients &&
        append!(results, python_results(opts, rows, iterations; strict = strict))
    "go" in clients && append!(results, go_results(opts, rows, iterations; strict = strict))
    "rust" in clients && append!(results, rust_results(opts, rows, iterations; strict = strict))

    mkpath(dirname(opts["output"]))
    open(opts["output"], "w") do io
        JSON3.pretty(io, results)
        println(io)
    end
    write_markdown(opts["markdown"], results, opts)
    print_results(results)
    println()
    println("Wrote ", opts["output"])
    println("Wrote ", opts["markdown"])
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end

# # Stream query results
#
# Use `select_callback` when the result may be too large to materialize. The
# callback receives one non-empty ClickHouse block at a time.

using ClickHouseClient

sock = connect("localhost"; username="default", compression=COMPRESSION_LZ4)

query = """
    SELECT service, latency_ms
    FROM app_events
    WHERE ts >= now64(9) - INTERVAL 1 DAY
"""

counts = Dict{String, Int}()
latency_sum = Dict{String, UInt128}()

select_callback(
    sock,
    query;
    progress_callback = p -> @info(
        "ClickHouse progress",
        rows=UInt64(p.rows),
        bytes=UInt64(p.bytes),
        total_rows=UInt64(p.total_rows),
    ),
) do block
    services = block[:service]
    latencies = block[:latency_ms]

    for (service, latency) in zip(services, latencies)
        key = String(service)
        counts[key] = get(counts, key, 0) + 1
        latency_sum[key] = get(latency_sum, key, UInt128(0)) + UInt128(latency)
    end
end

avg_latency = Dict(
    service => Float64(latency_sum[service]) / counts[service]
    for service in keys(counts)
)

avg_latency

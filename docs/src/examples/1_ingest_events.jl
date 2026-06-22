# # Ingest application events
#
# This example writes a typical observability/event table: nanosecond
# timestamps, low-cardinality dimensions, nullable user ids, UUID request ids,
# IP addresses, arrays, and decimal values.

using ClickHouseClient
using DataFrames
using Dates
using UUIDs
using DecFP
using Sockets: IPv4

sock = connect("localhost"; username="default", compression=COMPRESSION_LZ4)

execute(sock, """
    CREATE TABLE IF NOT EXISTS app_events
    (
        ts DateTime64(9, 'UTC'),
        service LowCardinality(String),
        level LowCardinality(String),
        request_id UUID,
        user_id Nullable(UInt64),
        path String,
        latency_ms UInt32,
        amount Decimal(18, 4),
        client_ip IPv4,
        tags Array(String)
    )
    ENGINE = MergeTree
    PARTITION BY toYYYYMM(ts)
    ORDER BY (service, ts)
""")

# ClickHouse stores DateTime64 as integer ticks. Use DateTime64{9} when you
# need nanosecond precision beyond Julia DateTime's millisecond precision.
events = Dict(
    :ts => DateTime64{9}.([
        1_767_268_800_123_456_789,
        1_767_268_801_010_000_000,
        1_767_268_802_999_999_999,
    ]),
    :service => ["api", "api", "worker"],
    :level => ["info", "warn", "info"],
    :request_id => UUID[
        UUID("c187abfa-31c1-4131-a33e-556f23f7aa67"),
        UUID("f9a7e2b9-dc22-4ca6-b4fe-83ba551ea3bb"),
        UUID("dc986a81-9f1d-4d96-b618-6e8d034285c1"),
    ],
    :user_id => Union{UInt64, Missing}[1001, missing, 1002],
    :path => ["/checkout", "/checkout", "/jobs/reconcile"],
    :latency_ms => UInt32[18, 431, 73],
    :amount => [Dec64("12.3400"), Dec64("0.0000"), Dec64("99.9900")],
    :client_ip => IPv4[
        IPv4("10.0.0.10"),
        IPv4("10.0.0.11"),
        IPv4("10.0.0.20"),
    ],
    :tags => [
        ["mobile", "checkout"],
        ["checkout", "upstream"],
        ["batch"],
    ],
)

insert(sock, "app_events", [events])

select_df(sock, """
    SELECT service, level, count() AS events, avg(latency_ms) AS avg_latency_ms
    FROM app_events
    GROUP BY service, level
    ORDER BY service, level
""")

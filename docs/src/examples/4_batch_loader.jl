# # Batch row records
#
# Many applications start with row-like data from JSON, Kafka, logs, or an API.
# Use `insert_records` to batch those records into native columnar ClickHouse
# blocks.

using ClickHouseClient
using UUIDs

sock = connect("localhost"; username="default", compression=COMPRESSION_LZ4)

rows = [
    Dict(
        :ts => DateTime64{9}(1_767_268_800_123_456_789),
        :service => "api",
        :level => "info",
        :request_id => UUID("c187abfa-31c1-4131-a33e-556f23f7aa67"),
        :user_id => UInt64(1001),
        :path => "/checkout",
        :latency_ms => UInt32(18),
    ),
    Dict(
        "ts" => DateTime64{9}(1_767_268_801_010_000_000),
        "service" => "api",
        "level" => "warn",
        "request_id" => UUID("f9a7e2b9-dc22-4ca6-b4fe-83ba551ea3bb"),
        "user_id" => missing,
        "path" => "/checkout",
        "latency_ms" => UInt32(431),
    ),
]

insert_records(sock, "app_events", rows; block_size=50_000)

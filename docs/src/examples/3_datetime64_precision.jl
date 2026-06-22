# # DateTime64 precision
#
# `DateTime64(P)` values are signed integer ticks at precision `P`. Julia
# `DateTime` has millisecond precision, so nanosecond values should stay as
# `DateTime64{9}` or raw ticks.

using ClickHouseClient
using Dates

sock = connect("localhost"; username="default")

execute(sock, """
    CREATE TABLE IF NOT EXISTS timestamp_precision
    (
        id UInt64,
        ts_ms DateTime64(3, 'UTC'),
        ts_ns DateTime64(9, 'UTC')
    )
    ENGINE = Memory
""")

insert(sock, "timestamp_precision", [Dict(
    :id => UInt64[1, 2],
    :ts_ms => DateTime64.(DateTime[
        DateTime(2026, 1, 1, 0, 0, 0, 123),
        DateTime(2026, 1, 1, 0, 0, 1, 456),
    ], 3),
    :ts_ns => DateTime64{9}.([
        1_767_225_600_123_456_789,
        1_767_225_601_456_000_001,
    ]),
)])

result = query(sock, "SELECT id, ts_ms, ts_ns FROM timestamp_precision ORDER BY id")

# Millisecond-precision values can be converted to Julia DateTime exactly.
DateTime.(result[:ts_ms])

# Nanosecond values can be inspected as raw ClickHouse ticks.
Int64.(result[:ts_ns])

# This conversion throws unless the nanosecond value lands exactly on a
# millisecond boundary.
try
    DateTime.(result[:ts_ns])
catch err
    @info "expected precision loss guard" exception=(err, catch_backtrace())
end

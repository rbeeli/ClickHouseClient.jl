# Date/time and time zones

ClickHouse stores date/time values in compact native formats. The client keeps
that model visible so precision, timezone conversion, and raw ticks are
predictable.

## Type choices

Use `DateTime` only for whole-second timestamps. Use `DateTime64(P)` when the
data has subsecond precision.

| ClickHouse type | Use when | Julia read type |
| --- | --- | --- |
| `Date` | Calendar dates in the classic ClickHouse range | `Date` |
| `Date32` | Wider date range | `Date` |
| `DateTime` | Whole-second instants | `DateTime` |
| `DateTime('Zone')` | Whole-second instants displayed in a timezone | `ZonedDateTime` |
| `DateTime64(P)` | Exact subsecond ticks | `DateTime64{P}` |
| `DateTime64(P, 'Zone')`, `P <= 3` | Millisecond-or-coarser instants displayed in a timezone | `ZonedDateTime` |
| `DateTime64(P, 'Zone')`, `P > 3` | Microsecond or nanosecond ticks with timezone metadata | `ClickHouseZonedDateTime64{P}` |

## DateTime

ClickHouse `DateTime` stores whole seconds as UTC epoch seconds. A Julia
`DateTime` with milliseconds is rejected because writing it would silently lose
data.

```julia
using Dates

insert(sock, "events", [Dict(
    :created_at => DateTime[DateTime(2026, 1, 1, 12, 0, 0)],
)])

# Throws: DateTime cannot represent milliseconds in ClickHouse DateTime.
insert(sock, "events", [Dict(
    :created_at => DateTime[DateTime(2026, 1, 1, 12, 0, 0, 100)],
)])
```

## DateTime64

ClickHouse `DateTime64(P)` stores signed integer ticks at precision `P`, where
`P` is from 0 through 9. `DateTime64{P}` preserves those ticks exactly.

```julia
using Dates
using ClickHouseClient

DateTime64(DateTime(2026, 1, 1, 12, 0, 0, 123), 3)
DateTime64(DateTime(2026, 1, 1, 12, 0, 0, 123), 6)
DateTime64{9}(1_767_268_800_123_456_789)
```

`DateTime64` converts back to Julia `DateTime` only when the tick value is
exactly representable at Julia's millisecond precision:

```julia
DateTime(DateTime64{6}(1_767_268_800_123_000))

# Throws because 456 microseconds would be lost.
DateTime(DateTime64{6}(1_767_268_800_123_456))
```

Use `Int64(x)` when you need the exact raw tick value:

```julia
x = DateTime64{9}(1_767_268_800_123_456_789)
Int64(x)
```

## Timezone columns

ClickHouse stores `DateTime` and `DateTime64` as epoch values and uses the
type's timezone metadata for display and parsing. For timezone-qualified
columns, the client uses TimeZones.jl.

```julia
using Dates
using TimeZones

zurich = TimeZone("Europe/Zurich")

rows = [Dict(
    :created_at => ZonedDateTime(DateTime(2026, 1, 1, 12, 0, 0), zurich),
)]

insert_records(sock, "events", rows)
```

A `DateTime('Europe/Zurich')` column reads back as `ZonedDateTime`:

```julia
result = query(sock, """
    SELECT toDateTime('2026-01-01 12:00:00', 'Europe/Zurich') AS created_at
""")

result[:created_at][1]
# ZonedDateTime(2026, 1, 1, 12, tz"Europe/Zurich")
```

## Timezone DateTime64

For `DateTime64(P, 'Zone')`, the read type depends on precision.

For `P <= 3`, TimeZones.jl can represent the value exactly because
`ZonedDateTime` wraps Julia `DateTime`, which has millisecond precision:

```julia
result = query(sock, """
    SELECT toDateTime64('2026-01-01 12:00:00.123', 3, 'Europe/Zurich') AS ts
""")

result[:ts][1]
# ZonedDateTime(2026, 1, 1, 12, 0, 0, 123, tz"Europe/Zurich")
```

For `P > 3`, the client returns `ClickHouseZonedDateTime64{P}` so it can keep
both the exact UTC ticks and the ClickHouse timezone metadata:

```julia
result = query(sock, """
    SELECT toDateTime64('2026-01-01 12:00:00.123456', 6, 'Europe/Zurich') AS ts
""")

ts = result[:ts][1]
Int64(ts)        # exact UTC microsecond ticks
ts.utc           # DateTime64{6}(...)
ts.timezone      # tz"Europe/Zurich"
```

Use `ZonedDateTime` for millisecond-or-coarser timezone values. Use
`ClickHouseZonedDateTime64{P}` or `DateTime64{P}` when microsecond or
nanosecond precision is important.

## Writing rules

`DateTime` and `DateTime64` inputs are interpreted as UTC instants. Use
`ZonedDateTime` when the value is naturally in a local timezone:

```julia
zurich = TimeZone("Europe/Zurich")

insert_records(sock, "events", [Dict(
    :ts_seconds => ZonedDateTime(DateTime(2026, 1, 1, 12), zurich),
    :ts_ms => ZonedDateTime(DateTime(2026, 1, 1, 12, 0, 0, 123), zurich),
)])
```

For high-precision timezone columns, write exact UTC ticks:

```julia
insert_records(sock, "events", [Dict(
    :ts_us => ClickHouseZonedDateTime64{6}(
        1_767_268_800_123_456,
        TimeZone("UTC"),
    ),
)])
```

The wrapper stores timezone metadata for results and user code. On insert, the
native wire value is still the UTC tick count required by ClickHouse.

## Practical guidance

Prefer UTC schemas for ingestion pipelines unless users need ClickHouse to
display values in a specific timezone. Use timezone-qualified columns when the
timezone is part of the schema contract.

Avoid mixing timezone-naive `DateTime` values with local civil times. If a value
comes from a local clock, construct a `ZonedDateTime` before inserting it.

Keep nanosecond values as `DateTime64{9}` or `ClickHouseZonedDateTime64{9}`.
Convert to `DateTime` only after deciding that millisecond precision is enough.

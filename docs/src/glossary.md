# Glossary

## Block

A ClickHouse native data packet containing a set of columns and a row count.
Inserts and selects both use blocks.

## Columnar insert

An insert where data is grouped by column rather than by row. In this client, a
columnar insert block is usually supplied as `Dict{Symbol, AbstractVector}` or
through any Tables.jl-compatible source via `insert_table`.

## Record insert

An insert where input data is grouped by row. `insert_records` accepts an
iterable of row dictionaries and batches them into columnar blocks before
writing them to ClickHouse.

## Native protocol

ClickHouse's TCP binary protocol. It avoids text serialization and carries type
information, compressed data blocks, server progress packets, profile packets,
and exceptions.

## Sample block

The empty block sent by ClickHouse after an `INSERT` query starts. It tells the
client which columns and ClickHouse types the server expects.

## LowCardinality

A ClickHouse type that stores a dictionary plus integer keys. It is useful for
repeated strings such as service names, hosts, regions, symbols, or status
codes.

## Nullable

A ClickHouse wrapper type that adds a null bitmap to another type. In Julia,
nullable values are represented with `missing`.

## DateTime64

A ClickHouse timestamp stored as signed integer ticks with configurable
precision from 0 through 9. `DateTime64(9)` is nanosecond precision.

## Progress packet

A server packet sent while a query is running. It reports incremental rows,
bytes, and total rows. The client can pass these packets to
`progress_callback`.

## Profile packet

A server packet with query profile summary data. The client consumes it as part
of normal response draining.

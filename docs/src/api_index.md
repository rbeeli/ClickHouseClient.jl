# API index

This is the public API exported by `ClickHouseClient`.

## Connection and socket state

- `connect`
- `close`
- `ping`
- `is_connected`
- `is_busy`
- `AbstractTransport`
- `TLSConfig`
- `NativeTCP`
- `ClickHouseSock`

## Query execution

- `execute`
- `insert`
- `insert_records`
- `insert_table`
- `query`
- `select_df`
- `select_channel`
- `select_callback`
- `result_dict`
- `columnnames`
- `columntypes`
- `nrows`
- `cancel`
- `table_status`
- `QueryOptions`
- `QuerySetting`
- `QueryStats`
- `QuerySchema`
- `QueryBlock`
- `QueryResult`
- `QueryStage`
- `QUERY_STAGE_FETCH_COLUMNS`
- `QUERY_STAGE_WITH_MERGEABLE_STATE`
- `QUERY_STAGE_COMPLETE`
- `OpenTelemetryContext`
- `ExternalTable`

## Compression

- `Compression`
- `COMPRESSION_NONE`
- `COMPRESSION_LZ4`
- `COMPRESSION_LZ4HC`
- `COMPRESSION_ZSTD`
- `COMPRESSION_CHECKSUM_ONLY`

## Data types

- `DateTime64`
- `ClickHouseZonedDateTime64`
- `ClickHouseDecimal32`
- `ClickHouseDecimal64`
- `ClickHouseDecimal128`
- `ClickHouseDecimal256`
- `Block`
- `Column`
- `TableRef`
- `TableStatus`

## Errors

- `ClickHouseServerException`
- `UnsupportedProtocolFeature`
- `ConnectTimeoutError`

## Docstrings

```@docs
AbstractTransport
TLSConfig
NativeTCP
connect
ping
execute
insert
insert_records
insert_table
query
select_df
select_channel
select_callback
result_dict
cancel
table_status
QueryOptions
QuerySetting
QueryStats
OpenTelemetryContext
ExternalTable
QuerySchema
QueryBlock
QueryResult
ClickHouseZonedDateTime64
ClickHouseDecimal32
ClickHouseDecimal64
ClickHouseDecimal128
ClickHouseDecimal256
Block
Column
TableRef
TableStatus
UnsupportedProtocolFeature
ConnectTimeoutError
```

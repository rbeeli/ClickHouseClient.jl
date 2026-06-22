# Connections

ClickHouseClient.jl talks to ClickHouse over the native TCP protocol, usually
on port `9000`. Native TCP over TLS usually listens on port `9440`. This is
separate from ClickHouse's HTTP/HTTPS interface.

## Opening a connection

```julia
sock = connect(
    "localhost";
    database="default",
    username="default",
    password="",
    compression=COMPRESSION_NONE,
)
```

`connect` returns a `ClickHouseSock`. It stores the server revision,
timezone, display name, settings, and the underlying TCP stream.

Use `NativeTCP(port=...)` when the server listens on a non-default port:

```julia
sock = connect(
    "localhost";
    username="default",
    transport=NativeTCP(port=19000),
)
```

## Native TCP over TLS

Use `NativeTCP(tls=TLSConfig())` for secure native TCP:

```julia
sock = connect(
    "clickhouse.internal";
    username="default",
    transport=NativeTCP(tls=TLSConfig()),
)
```

When `port` is omitted, `NativeTCP()` uses port `9000` and
`NativeTCP(tls=TLSConfig())` uses port `9440`. Use `NativeTCP(port=...)` to
override either default.

TLS verifies the server certificate by default. If the server uses a private
certificate authority, pass a CA bundle file or CA directory:

```julia
sock = connect(
    "clickhouse.internal";
    username="default",
    transport=NativeTCP(tls=TLSConfig(
        ca_roots="/etc/ssl/clickhouse-ca.crt",
    )),
)
```

If you connect to an IP address but the certificate is issued for a DNS name,
override the TLS hostname. The TCP connection still uses the first argument;
`hostname` is used for SNI and certificate verification.

```julia
sock = connect(
    "10.0.12.34";
    username="default",
    transport=NativeTCP(tls=TLSConfig(
        ca_roots="/etc/ssl/clickhouse-ca.crt",
        hostname="clickhouse.internal",
    )),
)
```

`TLSConfig(verify=false)` disables server certificate verification. Use it only
for local throwaway test servers; it still encrypts traffic, but it does not
prove which server you connected to.

Client certificates for mutual TLS are not supported yet.

## Compression

Use LZ4 or ZSTD compression for large inserts and result sets:

```julia
sock = connect("localhost"; username="default", compression=COMPRESSION_LZ4)
```

Compression is negotiated per query and applies to native data blocks. It is
usually worth enabling when rows are wide or when the client and server are not
on the same host. Compression works with both plain native TCP and native TCP
over TLS.

Available modes are:

- `COMPRESSION_NONE`: no compressed block envelope.
- `COMPRESSION_CHECKSUM_ONLY`: native block envelope and checksum without
  compression.
- `COMPRESSION_LZ4`: ClickHouse LZ4 block compression.
- `COMPRESSION_LZ4HC`: high-compression LZ4 encoder. It uses the same
  ClickHouse wire method as LZ4 and is decompressed by servers as LZ4.
- `COMPRESSION_ZSTD`: ClickHouse ZSTD block compression.

## Timeouts and buffers

```julia
sock = connect(
    "clickhouse.internal";
    username="default",
    connection_timeout=10,
    send_buffer_size=1 << 20,
    max_insert_block_size=1_000_000,
    max_string_size=1 << 30,
    max_column_size_bytes=1 << 30,
    max_compressed_block_size=1 << 30,
    max_uncompressed_block_size=1 << 30,
)
```

`connection_timeout` controls TCP connection establishment. A timeout throws
`ConnectTimeoutError`. `send_buffer_size` sets Julia's socket write buffer.
`max_insert_block_size` is stored in settings for callers that want to align
their own batching policy with ClickHouse's usual insert block size.

Incoming native protocol lengths are checked before allocating buffers.
`max_string_size`, `max_column_size_bytes`, `max_compressed_block_size`, and
`max_uncompressed_block_size` default to 1 GiB. Raise them only when the server
is trusted and the workload is expected to return larger individual strings,
columns, or compressed blocks.

## Socket lifecycle

A `ClickHouseSock` handles one request at a time. The client marks it busy while
a query is in flight and rejects concurrent use.

```julia
is_connected(sock)
is_busy(sock)
```

If a request throws, the client closes the socket. The native protocol is a
stream; after an exception, there may be unread packets in the stream, so
reusing the same connection can corrupt the next request.

```julia
try
    execute(sock, "SELECT * FROM missing_table")
catch err
    @assert !is_connected(sock)
    sock = connect("localhost"; username="default")
end
```

## Recommended pattern

For a service, keep a small pool of sockets and never share the same socket
between concurrent tasks. For a batch job, use one socket per worker task and
reconnect on failure.

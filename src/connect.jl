Base.flush(sock::ClickHouseSock) = Base.flush(sock.io)

function write_connection_addendum(sock::ClickHouseSock)::Nothing
    rev = sock.server_rev
    has_addendum(rev) || return nothing

    has_addendum_quota_key(rev) && chwrite(sock, "")
    if has_chunked_packets(rev)
        chwrite(sock, "notchunked")
        chwrite(sock, "notchunked")
    end
    has_versioned_parallel_replicas_protocol(rev) &&
        chwrite(sock, VarUInt(PARALLEL_REPLICAS_PROTOCOL_VERSION))
    flush(sock)
    return nothing
end

function Base.close(sock::ClickHouseSock)
    @guarded sock begin
        if !sock.closed
            Base.close(sock.io)
        end
        sock.closed = true
        sock.busy = false
        sock.query_compression = nothing
    end
end

function open_tcp(settings::CHSettings; buffer_writes::Bool = true)::Sockets.TCPSocket
    tcp = Sockets.TCPSocket()
    connect_task = nothing
    timed_out = false

    try
        buffer_writes && Base.buffer_writes(tcp, settings.send_buffer_size)

        connect_task = @async begin
            Sockets.connect!(tcp, settings.host, settings.port)
            Sockets.wait_connected(tcp)
            return nothing
        end

        if timedwait(() -> istaskdone(connect_task), settings.connection_timeout) == :timed_out
            timed_out = true
            @async begin
                try
                    close(tcp)
                catch
                end
                try
                    wait(connect_task)
                catch
                end
            end
            throw(ConnectTimeoutError(
                settings.host,
                settings.port,
                settings.connection_timeout,
            ))
        end

        fetch(connect_task)
    catch
        if timed_out
            rethrow()
        elseif connect_task isa Task && !istaskdone(connect_task)
            @async begin
                try
                    close(tcp)
                catch
                end
            end
        else
            Base.close(tcp)
        end
        rethrow()
    end

    return tcp
end

open_stream(settings::CHSettings, ::NativeTCP{Nothing}) = open_tcp(settings)

function open_stream(settings::CHSettings, transport::NativeTCP{TLSConfig})
    tcp = open_tcp(settings; buffer_writes = false)
    ssl = nothing
    try
        tls = transport.tls
        context = if isnothing(tls.ca_roots)
            OpenSSL.SSLContext(OpenSSL.TLSClientMethod())
        else
            OpenSSL.SSLContext(OpenSSL.TLSClientMethod(), tls.ca_roots)
        end
        ssl = OpenSSL.SSLStream(context, tcp)
        OpenSSL.hostname!(ssl, something(tls.hostname, settings.host))
        OpenSSL.connect(ssl; require_ssl_verification = tls.verify)
        return BufferedWriteIO(ssl, settings.send_buffer_size)
    catch
        if isnothing(ssl)
            Base.close(tcp)
        else
            Base.close(ssl)
        end
        rethrow()
    end
end

function initialize_connection!(sock::ClickHouseSock)::ClickHouseSock
    try
        set_busy!(sock, true)
        hello = ClientHello(
            CLIENT_NAME,
            CLIENT_PROTOCOL_MAJOR,
            CLIENT_PROTOCOL_MINOR,
            CLIENT_PROTOCOL_REVISION,
            sock.settings.database,
            sock.settings.username,
            sock.settings.password
        )

        write_packet(sock, hello)
        info = read_server_packet(sock)::ServerInfo
        @guarded sock begin
            sock.server_name = isempty(info.server_display_name) ?
                            info.server_name : info.server_display_name
            sock.server_rev = negotiated_protocol_revision(info.server_rev)
            sock.server_timezone = info.server_timezone
        end
        write_connection_addendum(sock)
        set_busy!(sock, false)
    catch
        close(sock)
        rethrow()
    end

    return sock
end

"""
    connect(host; username, transport = NativeTCP(), kwargs...)

Return a `ClickHouseSock` connected to a ClickHouse server.
"""
function connect(
    host::AbstractString;
    username::AbstractString,
    transport::AbstractTransport = NativeTCP(),
    kwargs...,
)
    return connect(transport, host; username = username, kwargs...)
end

function connect(transport::AbstractTransport, host::AbstractString; kwargs...)
    throw(ArgumentError("Unsupported ClickHouse transport: $(typeof(transport))"))
end

function connect(
    transport::NativeTCP,
    host::AbstractString;
    username::AbstractString,
    database::AbstractString = "",
    password::AbstractString = "",
    connection_timeout = DBMS_DEFAULT_CONNECT_TIMEOUT,
    max_insert_block_size = DBMS_DEFAULT_MAX_INSERT_BLOCK,
    send_buffer_size = DBMS_DEFAULT_BUFFER_SIZE,
    compression::Compression = COMPRESSION_NONE,
    max_string_size = DBMS_DEFAULT_MAX_STRING_SIZE,
    max_column_size_bytes = DBMS_DEFAULT_MAX_COLUMN_SIZE_BYTES,
    max_compressed_block_size = DBMS_DEFAULT_MAX_COMPRESSED_BLOCK_SIZE,
    max_uncompressed_block_size = DBMS_DEFAULT_MAX_UNCOMPRESSED_BLOCK_SIZE,
)
    settings = CHSettings(
        host = host,
        username = username,
        transport = transport,
        database = database,
        password = password,
        connection_timeout = connection_timeout,
        max_insert_block_size = max_insert_block_size,
        send_buffer_size = send_buffer_size,
        compression = compression,
        max_string_size = max_string_size,
        max_column_size_bytes = max_column_size_bytes,
        max_compressed_block_size = max_compressed_block_size,
        max_uncompressed_block_size = max_uncompressed_block_size,
    )

    io = open_stream(settings, settings.transport)
    sock = ClickHouseSock(io, settings)
    return initialize_connection!(sock)
end

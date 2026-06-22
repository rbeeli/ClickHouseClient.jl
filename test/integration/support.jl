function live_tests_enabled()
    return lowercase(get(ENV, "CLICKHOUSECLIENT_TEST_LIVE", "")) in ("1", "true", "yes")
end

function recursive_miss_cmp(a::AbstractVector, b::AbstractVector)
    length(a) != length(b) && return false
    for i in eachindex(a)
        recursive_miss_cmp(a[i], b[i]) || return false
    end
    return true
end

function recursive_miss_cmp(a, b)
    return (ismissing(a) && ismissing(b)) || (!ismissing(a == b) && a == b)
end

function reconnect_like(sock)
    settings = sock.settings
    return connect(
        settings.host;
        username = settings.username,
        transport = settings.transport,
        database = settings.database,
        password = settings.password,
        connection_timeout = settings.connection_timeout,
        max_insert_block_size = settings.max_insert_block_size,
        send_buffer_size = settings.send_buffer_size,
        compression = settings.compression,
    )
end

function cleanup_execute(sock, query)
    cleanup_sock = sock
    close_cleanup_sock = false
    try
        if !is_connected(cleanup_sock)
            cleanup_sock = reconnect_like(sock)
            close_cleanup_sock = true
        end
        execute(cleanup_sock, query)
    catch
        # Best-effort cleanup should not mask the test failure that triggered it.
    finally
        close_cleanup_sock && close(cleanup_sock)
    end
end

function connection_kwargs()
    password = get(ENV, "CLICKHOUSECLIENT_TEST_PASSWORD", "")
    kwargs = (
        username = get(ENV, "CLICKHOUSECLIENT_TEST_USER", "default"),
        database = get(ENV, "CLICKHOUSECLIENT_TEST_DATABASE", ""),
        password = password,
    )
    return kwargs
end

function live_connect(; compression = COMPRESSION_NONE)
    host = get(ENV, "CLICKHOUSECLIENT_TEST_HOST", "localhost")
    kwargs = connection_kwargs()
    return connect(
        host;
        username = kwargs.username,
        database = kwargs.database,
        password = kwargs.password,
        compression = compression,
    )
end

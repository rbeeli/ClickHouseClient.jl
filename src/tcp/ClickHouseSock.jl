"""
Supertype for connection transports supported by `connect`.
"""
abstract type AbstractTransport end

"""
    TLSConfig(; verify = true, ca_roots = nothing, hostname = nothing)

TLS settings for transports that support encrypted connections.

`verify` controls server certificate verification and should normally stay
enabled. `ca_roots` may point to a CA bundle file or CA directory when the
server certificate is not trusted by Julia's default CA roots. `hostname`
overrides the host name used for SNI and certificate verification, which is
useful when connecting to an IP address.
"""
Base.@kwdef struct TLSConfig
    verify::Bool = true
    ca_roots::Union{Nothing, String} = nothing
    hostname::Union{Nothing, String} = nothing
end

"""
    NativeTCP(; tls = nothing, port = nothing)

ClickHouse native TCP transport. Omitted ports resolve to `9000` for plain TCP
and `9440` for native TCP over TLS. This is not the HTTP/HTTPS interface.
"""
struct NativeTCP{T<:Union{Nothing, TLSConfig}} <: AbstractTransport
    tls::T
    port::Union{Nothing, Int}
end

function NativeTCP(;
    tls::Union{Nothing, TLSConfig} = nothing,
    port::Union{Nothing, Integer} = nothing,
)
    resolved_port = isnothing(port) ? nothing : Int(port)
    if isnothing(tls)
        return NativeTCP{Nothing}(nothing, resolved_port)
    else
        return NativeTCP{TLSConfig}(tls, resolved_port)
    end
end

resolve_port(transport::NativeTCP{Nothing}) =
    something(transport.port, DBMS_DEFAULT_TCP_PORT)

resolve_port(transport::NativeTCP{TLSConfig}) =
    something(transport.port, DBMS_DEFAULT_SECURE_TCP_PORT)

struct CHSettings{T<:AbstractTransport}
    host::String
    port::Int
    transport::T
    database::String
    username::String
    password::String
    connection_timeout::Int
    max_insert_block_size::Int
    send_buffer_size::Int
    compression::Compression
    max_string_size::Int
    max_column_size_bytes::Int
    max_compressed_block_size::Int
    max_uncompressed_block_size::Int
end

function validate_byte_limit(name::AbstractString, value)::Int
    limit = Int(value)
    limit >= 0 ||
        throw(ArgumentError("$(name) must be non-negative"))
    return limit
end

function CHSettings(;
    host::AbstractString,
    username::AbstractString,
    transport::T = NativeTCP(),
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
) where {T<:AbstractTransport}
    return CHSettings{T}(
        String(host),
        resolve_port(transport),
        transport,
        String(database),
        String(username),
        String(password),
        Int(connection_timeout),
        Int(max_insert_block_size),
        Int(send_buffer_size),
        compression,
        validate_byte_limit("max_string_size", max_string_size),
        validate_byte_limit("max_column_size_bytes", max_column_size_bytes),
        validate_byte_limit("max_compressed_block_size", max_compressed_block_size),
        validate_byte_limit("max_uncompressed_block_size", max_uncompressed_block_size),
    )
end

test_settings() = CHSettings(host = "", username = "")

"""is compression enabled in these settings?"""
compression_enabled(settings::CHSettings) = settings.compression != COMPRESSION_NONE

mutable struct ClickHouseSock{I<:IO,S<:CHSettings}
    io::I
    settings::S
    lock::ReentrantLock
    busy::Bool
    closed::Bool
    query_compression::Union{Nothing, Compression}
    server_name::String
    server_rev::Int
    server_timezone::Union{String, Nothing}

    function ClickHouseSock(io::I, settings::S = test_settings()) where {I<:IO,S<:CHSettings}
        return new{I,S}(
            io,
            settings,
            ReentrantLock(),
            false,
            false,
            nothing,
            "", 0, nothing
        )
    end
end

"""is compression enabled on this socket?"""
active_compression(sock::ClickHouseSock) =
    isnothing(sock.query_compression) ? sock.settings.compression : sock.query_compression

"""is compression enabled on this socket?"""
compression_enabled(sock::ClickHouseSock) = active_compression(sock) != COMPRESSION_NONE

is_open_io(io::IO)::Bool = try
    isopen(io)
catch e
    e isa MethodError || rethrow(e)
    true
end

"""
    @guarded(sock::ClickHouseSock, expr)

    Run `expr` thread-safe under lock of `sock.lock`.
"""
macro guarded(sock, expr)
    quote
        lock($(esc(sock)).lock)
        local res = try
            $(esc(expr))
        catch e
            unlock($(esc(sock)).lock)
            rethrow(e)
        end
        unlock($(esc(sock)).lock)
        res
    end
end

is_connected(sock::ClickHouseSock) =
    @guarded sock !sock.closed && is_open_io(sock.io)

is_busy(sock::ClickHouseSock) = @guarded sock sock.busy

set_busy!(sock::ClickHouseSock, value::Bool) =
                        @guarded sock sock.busy = value


"""
    @using_socket(sock::ClickHouseSock, expr)

    Set `sock.busy` status and run `expr`.
    Raises an exception if `sock` is not connected or already busy.
    If an exception occurs during the execution of an expression, the socket will
    disconnect. After a failed request the ClickHouse native protocol state may
    be partially consumed, so reusing the same connection is not safe.
"""
macro using_socket(sock, expr)
    quote
        @guarded $(esc(sock)) begin
            (!is_connected($(esc(sock)))) && error("ClickHouseSock not connected")
            $(esc(sock)).busy && error("ClickHouseSock is busy")
            $(esc(sock)).busy = true
        end
        local res = try
            $(esc(expr))
        catch e
            close($(esc(sock)))
            rethrow(e)
        finally
            set_busy!($(esc(sock)), false)
        end
        res
    end
end

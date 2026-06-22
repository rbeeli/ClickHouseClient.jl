"""Exception packet returned by ClickHouse."""
struct ClickHouseServerException <: Exception
    code::Int
    name::String
    message::String
    stack_trace::String
    nested::Union{Nothing, ClickHouseServerException}
end

ClickHouseServerException(code::Integer, name::AbstractString, message::AbstractString) =
    ClickHouseServerException(Int(code), String(name), String(message), "", nothing)

function ClickHouseServerException(
    code::Integer,
    name::AbstractString,
    message::AbstractString,
    stack_trace::AbstractString,
    nested::Union{Nothing, ClickHouseServerException} = nothing,
)
    return ClickHouseServerException(
        Int(code),
        String(name),
        String(message),
        String(stack_trace),
        nested,
    )
end

function Base.showerror(io::IO, exc::ClickHouseServerException)
    print(io, "ClickHouseServerException(", exc.code, ", ", exc.name, "): ", exc.message)
    if !isempty(exc.stack_trace)
        print(io, "\nClickHouse stack trace:\n", exc.stack_trace)
    end
    if exc.nested !== nothing
        print(io, "\nNested exception: ")
        showerror(io, exc.nested)
    end
end

"""checksum (compressed block hash values) don't match"""
struct ChecksumError <: Exception end

"""Raised when the server asks for a native protocol feature this client cannot handle."""
struct UnsupportedProtocolFeature <: Exception
    message::String
end

"""Raised when a TCP connection attempt exceeds the configured timeout."""
struct ConnectTimeoutError <: Exception
    host::String
    port::Int
    timeout::Float64
end

ConnectTimeoutError(host::AbstractString, port::Integer, timeout::Real) =
    ConnectTimeoutError(String(host), Int(port), Float64(timeout))

function Base.showerror(io::IO, exc::ConnectTimeoutError)
    print(
        io,
        "Connection to ",
        exc.host,
        ":",
        exc.port,
        " timed out after ",
        exc.timeout,
        " seconds",
    )
end

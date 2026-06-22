mutable struct BufferedWriteIO{I<:IO} <: IO
    io::I
    buffer::Vector{UInt8}
    used::Int
end

function BufferedWriteIO(io::I, buffer_size::Integer) where {I<:IO}
    size = max(1, Int(buffer_size))
    return BufferedWriteIO{I}(io, Vector{UInt8}(undef, size), 0)
end

Base.isopen(io::BufferedWriteIO) = isopen(io.io)
Base.isreadable(io::BufferedWriteIO) = isreadable(io.io)
Base.iswritable(io::BufferedWriteIO) = iswritable(io.io)
Base.bytesavailable(io::BufferedWriteIO) = bytesavailable(io.io)
Base.eof(io::BufferedWriteIO) = eof(io.io)

function Base.flush(io::BufferedWriteIO)
    if io.used > 0
        buffer = io.buffer
        GC.@preserve buffer begin
            unsafe_write(io.io, pointer(buffer), UInt(io.used))
        end
        io.used = 0
    end
    flush(io.io)
end

function Base.close(io::BufferedWriteIO)
    try
        flush(io)
    finally
        close(io.io)
    end
end

Base.unsafe_read(io::BufferedWriteIO, ptr::Ptr{UInt8}, nbytes::UInt) =
    unsafe_read(io.io, ptr, nbytes)

function Base.unsafe_write(io::BufferedWriteIO, ptr::Ptr{UInt8}, nbytes::UInt)
    n = Int(nbytes)
    n == 0 && return 0

    capacity = length(io.buffer)
    if n >= capacity
        flush(io)
        return unsafe_write(io.io, ptr, nbytes)
    end

    if io.used + n > capacity
        flush(io)
    end

    buffer = io.buffer
    GC.@preserve buffer begin
        unsafe_copyto!(pointer(buffer, io.used + 1), ptr, n)
    end
    io.used += n
    return n
end

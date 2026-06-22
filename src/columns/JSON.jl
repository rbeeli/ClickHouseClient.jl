is_ch_type(::Val{:JSON}) = true

const JSON_NATIVE_STRING_VERSION = UInt64(1)

struct JSONState
    version::UInt64
end

result_type(::Val{:JSON}, args...) = Vector{JSON3.Object}

function read_state_prefix(sock::ClickHouseSock, ::Val{:JSON}, args...)
    version = chread(sock, UInt64)
    version == JSON_NATIVE_STRING_VERSION ||
        error(
            "unsupported JSON native serialization version $(version); " *
            "use output_format_native_write_json_as_string=1"
        )
    return JSONState(version)
end

function write_state_prefix(sock::ClickHouseSock, ::Val{:JSON}, args...)
    chwrite(sock, JSON_NATIVE_STRING_VERSION)
    return nothing
end

json_string(value::AbstractString) = String(value)
json_string(value) = JSON3.write(value)

function parse_json_object(value::String)
    parsed = JSON3.read(value)
    parsed isa JSON3.Object ||
        throw(ArgumentError("ClickHouse JSON columns must contain JSON objects, got $(typeof(parsed))"))
    return parsed
end

function read_col_data(
    sock::ClickHouseSock,
    num_rows::VarUInt,
    ::Val{:JSON},
    ast::TypeAst,
    args...,
)
    state = ast.state isa JSONState ? ast.state : JSONState(JSON_NATIVE_STRING_VERSION)
    state.version == JSON_NATIVE_STRING_VERSION ||
        error("unsupported JSON native serialization version $(state.version)")
    strings = chread(sock, Vector{String}, num_rows)
    result = Vector{JSON3.Object}(undef, length(strings))
    for i in eachindex(strings)
        result[i] = parse_json_object(strings[i])
    end
    return result
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector,
    ::Val{:JSON},
    ast::TypeAst,
    args...,
)
    strings = Vector{String}(undef, length(data))
    for (i, value) in pairs(data)
        strings[i] = json_string(value)
        parse_json_object(strings[i])
    end
    chwrite(sock, strings)
    return nothing
end

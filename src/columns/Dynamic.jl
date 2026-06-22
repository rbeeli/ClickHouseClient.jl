is_ch_type(::Val{:Dynamic}) = true

const DYNAMIC_VERSION_V1 = UInt64(0)
const DYNAMIC_VERSION_V2 = UInt64(2)
const DYNAMIC_VERSION_V3 = UInt64(4)
const DYNAMIC_VERSION_FLATTENED = UInt64(3)
const DYNAMIC_SHARED_VARIANT = "SharedVariant"

struct DynamicState
    variant_ast::TypeAst
    type_names::Vector{String}
    shared_index::Int
    version::UInt64
end

abstract type AbstractClickHouseDynamic end

struct ClickHouseDynamic{T} <: AbstractClickHouseDynamic
    type_name::String
    value::T
end

ClickHouseDynamic(value::T) where {T} = ClickHouseDynamic{T}(string(T), value)

Base.show(io::IO, x::ClickHouseDynamic{T}) where {T} =
    print(io, "ClickHouseDynamic{$T}(", x.type_name, ", ", x.value, ")")

result_type(::Val{:Dynamic}, args...) = Vector{Union{Missing, AbstractClickHouseDynamic}}

function read_dynamic_type_names(sock::ClickHouseSock, version::UInt64)
    if version == DYNAMIC_VERSION_V1
        chread(sock, VarUInt) # historical max_dynamic_types, ignored by ClickHouse too
    elseif version == DYNAMIC_VERSION_FLATTENED
        error("flattened Dynamic native serialization is not supported")
    elseif !(version == DYNAMIC_VERSION_V2 || version == DYNAMIC_VERSION_V3)
        error("unsupported Dynamic serialization version: $(version)")
    end

    ntypes = checked_vector_length(sock, chread(sock, VarUInt), String)
    names = String[chread(sock, String) for _ in 1:ntypes]
    push!(names, DYNAMIC_SHARED_VARIANT)
    sort!(names)
    return names
end

function dynamic_type_ast(name::String)
    name == DYNAMIC_SHARED_VARIANT && return parse_typestring("String")
    return parse_typestring(name)
end

function dynamic_variant_ast(type_names::Vector{String})
    ast = TypeAst(:Variant)
    for name in type_names
        push!(ast, dynamic_type_ast(name))
    end
    return ast
end

function read_state_prefix(sock::ClickHouseSock, ::Val{:Dynamic}, args...)
    version = chread(sock, UInt64)
    type_names = read_dynamic_type_names(sock, version)
    variant_ast = dynamic_variant_ast(type_names)
    read_state_prefix(sock, variant_ast)
    shared_index = findfirst(==(DYNAMIC_SHARED_VARIANT), type_names)
    return DynamicState(variant_ast, type_names, shared_index, version)
end

function write_state_prefix(sock::ClickHouseSock, ::Val{:Dynamic}, ast::TypeAst, args...)
    chwrite(sock, DYNAMIC_VERSION_V2)
    chwrite(sock, VarUInt(0))
    variant_ast = dynamic_variant_ast([DYNAMIC_SHARED_VARIANT])
    write_state_prefix(sock, variant_ast)
    ast.state = DynamicState(variant_ast, [DYNAMIC_SHARED_VARIANT], 1, DYNAMIC_VERSION_V2)
    return nothing
end

const BINARY_TYPE_TO_NAME = Dict{UInt8,String}(
    0x00 => "Nothing",
    0x01 => "UInt8",
    0x02 => "UInt16",
    0x03 => "UInt32",
    0x04 => "UInt64",
    0x05 => "UInt128",
    0x06 => "UInt256",
    0x07 => "Int8",
    0x08 => "Int16",
    0x09 => "Int32",
    0x0a => "Int64",
    0x0b => "Int128",
    0x0c => "Int256",
    0x0d => "Float32",
    0x0e => "Float64",
    0x0f => "Date",
    0x10 => "Date32",
    0x11 => "DateTime",
    0x15 => "String",
    0x1d => "UUID",
    0x28 => "IPv4",
    0x29 => "IPv6",
    0x2d => "Bool",
    0x31 => "BFloat16",
    0x32 => "Time",
)

const NAME_TO_BINARY_TYPE = Dict(value => key for (key, value) in BINARY_TYPE_TO_NAME)

function decode_binary_type(sock::ClickHouseSock)::TypeAst
    tag = chread(sock, UInt8)
    if tag == 0x13
        ast = TypeAst(:DateTime64)
        push!(ast, string(chread(sock, UInt8)))
        return ast
    elseif tag == 0x19 || tag == 0x1a || tag == 0x1b || tag == 0x1c
        precision = chread(sock, UInt8)
        scale = chread(sock, UInt8)
        ast = TypeAst(:Decimal)
        push!(ast, string(precision))
        push!(ast, string(scale))
        return ast
    elseif tag == 0x34
        ast = TypeAst(:Time64)
        push!(ast, string(chread(sock, UInt8)))
        return ast
    end

    name = get(BINARY_TYPE_TO_NAME, tag, nothing)
    isnothing(name) && error("unsupported Dynamic shared binary type tag: 0x$(string(tag, base=16))")
    return TypeAst(Symbol(name))
end

function encode_binary_type(sock::ClickHouseSock, ast::TypeAst)
    if ast.name == :DateTime64
        chwrite(sock, UInt8(0x13))
        chwrite(sock, UInt8(parse_datetime64_precision(ast.args[1])))
    elseif ast.name == :Time64
        chwrite(sock, UInt8(0x34))
        chwrite(sock, UInt8(parse_time64_precision(ast.args[1])))
    elseif ast.name == :Decimal
        precision = parse(Int, ast.args[1])
        scale = parse_decimal_scale(ast.args[2])
        tag = precision <= 9 ? 0x19 :
              precision <= 18 ? 0x1a :
              precision <= 38 ? 0x1b : 0x1c
        chwrite(sock, UInt8(tag))
        chwrite(sock, UInt8(precision))
        chwrite(sock, UInt8(scale))
    else
        tag = get(NAME_TO_BINARY_TYPE, string(ast.name), nothing)
        isnothing(tag) && error("cannot encode Dynamic shared value of type $(ast.name)")
        chwrite(sock, UInt8(tag))
    end
    return nothing
end

function dynamic_ast_for_value(value)
    value isa Bool && return TypeAst(:Bool)
    value isa UInt8 && return TypeAst(:UInt8)
    value isa UInt16 && return TypeAst(:UInt16)
    value isa UInt32 && return TypeAst(:UInt32)
    value isa UInt64 && return TypeAst(:UInt64)
    value isa UInt128 && return TypeAst(:UInt128)
    value isa UInt256 && return TypeAst(:UInt256)
    value isa Int8 && return TypeAst(:Int8)
    value isa Int16 && return TypeAst(:Int16)
    value isa Int32 && return TypeAst(:Int32)
    value isa Int64 && return TypeAst(:Int64)
    value isa Int128 && return TypeAst(:Int128)
    value isa Int256 && return TypeAst(:Int256)
    value isa BFloat16 && return TypeAst(:BFloat16)
    value isa Float32 && return TypeAst(:Float32)
    value isa Float64 && return TypeAst(:Float64)
    value isa String && return TypeAst(:String)
    value isa UUID && return TypeAst(:UUID)
    value isa Sockets.IPv4 && return TypeAst(:IPv4)
    value isa Sockets.IPv6 && return TypeAst(:IPv6)
    value isa Date && return TypeAst(:Date32)
    value isa DateTime && return TypeAst(:DateTime)
    value isa DateTime64 && begin
        ast = TypeAst(:DateTime64)
        push!(ast, string(typeof(value).parameters[1]))
        return ast
    end
    value isa ClickHouseZonedDateTime64 && begin
        ast = TypeAst(:DateTime64)
        push!(ast, string(typeof(value).parameters[1]))
        return ast
    end
    value isa ClickHouseTime && return TypeAst(:Time)
    value isa ClickHouseTime64 && begin
        ast = TypeAst(:Time64)
        push!(ast, string(typeof(value).parameters[1]))
        return ast
    end
    value isa AbstractClickHouseDecimal && begin
        ast = TypeAst(:Decimal)
        push!(ast, string(decimal_precision(value)))
        push!(ast, string(decimal_scale(value)))
        return ast
    end
    throw(ArgumentError("cannot encode $(typeof(value)) as a Dynamic shared value"))
end

function read_binary_scalar(sock::ClickHouseSock, ast::TypeAst)
    ast.name == :Nothing && return missing
    if ast.name == :Bool
        byte = chread(sock, UInt8)
        (byte == 0x00 || byte == 0x01) ||
            throw(ArgumentError("Dynamic Bool contains invalid byte 0x$(string(byte, base=16))"))
        return byte == 0x01
    end
    ast.name == :Date && return Date(1970) + Day(chread(sock, UInt16))
    ast.name == :Date32 && return validate_date32(Date(1970) + Day(chread(sock, Int32)))
    ast.name == :DateTime && return unix2datetime(chread(sock, UInt32))
    ast.name == :DateTime64 && return DateTime64{parse_datetime64_precision(ast.args[1])}(chread(sock, Int64))
    ast.name == :Time && return ClickHouseTime(chread(sock, Int32))
    ast.name == :Time64 && return ClickHouseTime64{parse_time64_precision(ast.args[1])}(chread(sock, Int64))
    ast.name == :String && return chread(sock, String)
    ast.name == :UUID && return read_col_data(sock, VarUInt(1), ast)[1]
    ast.name == :IPv4 && return read_col_data(sock, VarUInt(1), ast)[1]
    ast.name == :IPv6 && return read_col_data(sock, VarUInt(1), ast)[1]
    ast.name == :Decimal && return read_col_data(sock, VarUInt(1), ast)[1]
    T = deserialize(Val(ast.name))
    return chread(sock, T)
end

function write_binary_scalar(sock::ClickHouseSock, ast::TypeAst, value)
    ast.name == :Bool && return chwrite(sock, UInt8(value))
    ast.name == :Date && return write_col_data(sock, Date[value], Val(:Date))
    ast.name == :Date32 && return write_col_data(sock, Date[value], Val(:Date32))
    ast.name == :DateTime && return write_col_data(sock, DateTime[value], Val(:DateTime))
    ast.name == :DateTime64 && return chwrite(sock, datetime64_ticks(value, parse_datetime64_precision(ast.args[1])))
    ast.name == :Time && return chwrite(sock, value.seconds)
    ast.name == :Time64 && return chwrite(sock, value.ticks)
    ast.name == :String && return chwrite(sock, String(value))
    ast.name == :UUID && return write_col_data(sock, [value], ast)
    ast.name == :IPv4 && return write_col_data(sock, [value], ast)
    ast.name == :IPv6 && return write_col_data(sock, [value], ast)
    ast.name == :Decimal && return write_col_data(sock, [value], ast)
    return chwrite(sock, value)
end

function decode_dynamic_shared_value(bytes::String)
    scratch = ClickHouseSock(IOBuffer(codeunits(bytes)))
    ast = decode_binary_type(scratch)
    value = read_binary_scalar(scratch, ast)
    return ClickHouseDynamic(string(ast.name), value)
end

function encode_dynamic_shared_value(value)::String
    payload = value isa ClickHouseDynamic ? value.value : value
    ast = dynamic_ast_for_value(payload)
    io = IOBuffer(read = true, write = true)
    scratch = ClickHouseSock(io)
    encode_binary_type(scratch, ast)
    write_binary_scalar(scratch, ast, payload)
    return String(take!(io))
end

function read_col_data(
    sock::ClickHouseSock,
    num_rows::VarUInt,
    ::Val{:Dynamic},
    ast::TypeAst,
    args...,
)
    state = ast.state isa DynamicState ? ast.state : error("Dynamic state prefix was not read")
    variants = read_col_data(sock, num_rows, state.variant_ast)
    result = Vector{Union{Missing, AbstractClickHouseDynamic}}(undef, length(variants))
    for i in eachindex(variants)
        value = variants[i]
        if ismissing(value)
            result[i] = missing
            continue
        end

        idx = Int(typeof(value).parameters[1])
        type_name = state.type_names[idx]
        if idx == state.shared_index
            result[i] = decode_dynamic_shared_value(value.value)
        else
            result[i] = ClickHouseDynamic(type_name, value.value)
        end
    end
    return result
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector,
    ::Val{:Dynamic},
    ast::TypeAst,
    args...,
)
    state = ast.state isa DynamicState ? ast.state : DynamicState(
        dynamic_variant_ast([DYNAMIC_SHARED_VARIANT]),
        [DYNAMIC_SHARED_VARIANT],
        1,
        DYNAMIC_VERSION_V2,
    )
    shared = Vector{Union{Missing, ClickHouseVariant{1,String}}}(undef, length(data))
    for i in eachindex(data)
        shared[i] = ismissing(data[i]) ? missing : ClickHouseVariant{1}(encode_dynamic_shared_value(data[i]))
    end
    write_col_data(sock, shared, state.variant_ast)
    return nothing
end

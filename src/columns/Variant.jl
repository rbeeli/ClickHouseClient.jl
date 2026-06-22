is_ch_type(::Val{:Variant}) = true

const VARIANT_DISCRIMINATORS_BASIC = UInt64(0)
const VARIANT_DISCRIMINATORS_COMPACT = UInt64(1)
const VARIANT_GRANULE_PLAIN = UInt8(0)
const VARIANT_GRANULE_COMPACT = UInt8(1)
const VARIANT_NULL_DISCRIMINATOR = UInt8(0xff)

struct VariantState
    discriminators_mode::UInt64
end

struct ClickHouseVariant{I,T}
    value::T
end

ClickHouseVariant{I}(value::T) where {I,T} = ClickHouseVariant{I,T}(value)

Base.show(io::IO, x::ClickHouseVariant{I,T}) where {I,T} =
    print(io, "ClickHouseVariant{$I,$T}(", x.value, ")")

variant_value_type(i::Integer, ast::TypeAst) =
    ClickHouseVariant{i, remove_vector_type(result_type(ast))}

function variant_union_type(args::TypeAst...)
    types = (Missing, (variant_value_type(i, args[i]) for i in eachindex(args))...)
    return Union{types...}
end

result_type(::Val{:Variant}, args::TypeAst...) = Vector{variant_union_type(args...)}

function read_state_prefix(sock::ClickHouseSock, ::Val{:Variant}, args::TypeAst...)
    mode = chread(sock, UInt64)
    mode == VARIANT_DISCRIMINATORS_BASIC ||
        mode == VARIANT_DISCRIMINATORS_COMPACT ||
        error("unsupported Variant discriminator serialization mode: $(mode)")
    for arg in args
        read_state_prefix(sock, arg)
    end
    return VariantState(mode)
end

function write_state_prefix(sock::ClickHouseSock, ::Val{:Variant}, args::TypeAst...)
    chwrite(sock, VARIANT_DISCRIMINATORS_BASIC)
    for arg in args
        write_state_prefix(sock, arg)
    end
    return nothing
end

function read_variant_discriminators_basic(sock::ClickHouseSock, num_rows::VarUInt)
    return chread(sock, Vector{UInt8}, num_rows)
end

function read_variant_discriminators_compact(sock::ClickHouseSock, num_rows::VarUInt)
    total_rows = checked_vector_length(sock, num_rows, UInt8)
    remaining = total_rows
    discriminators = Vector{UInt8}(undef, remaining)
    cursor = 1
    while remaining > 0
        granule_size64 = UInt64(chread(sock, VarUInt))
        granule_format = chread(sock, UInt8)
        granule_size64 > 0 ||
            error("Variant compact granule cannot be empty")
        granule_size64 <= UInt64(remaining) ||
            error("Variant compact granule has $(granule_size64) rows, only $(remaining) expected")
        granule_size = Int(granule_size64)
        if granule_format == VARIANT_GRANULE_COMPACT
            discr = chread(sock, UInt8)
            fill!(@view(discriminators[cursor:cursor + granule_size - 1]), discr)
        elseif granule_format == VARIANT_GRANULE_PLAIN
            values = chread(sock, Vector{UInt8}, VarUInt(granule_size))
            copyto!(discriminators, cursor, values, 1, length(values))
        else
            error("unexpected Variant compact granule format: $(granule_format)")
        end
        cursor += granule_size
        remaining -= granule_size
    end
    return discriminators
end

function read_variant_discriminators(sock::ClickHouseSock, num_rows::VarUInt, state::VariantState)
    if state.discriminators_mode == VARIANT_DISCRIMINATORS_BASIC
        return read_variant_discriminators_basic(sock, num_rows)
    else
        return read_variant_discriminators_compact(sock, num_rows)
    end
end

function variant_counts(discriminators::Vector{UInt8}, nvariants::Int)
    counts = zeros(UInt64, nvariants)
    for discr in discriminators
        discr == VARIANT_NULL_DISCRIMINATOR && continue
        idx = Int(discr) + 1
        1 <= idx <= nvariants ||
            error("Variant discriminator $(discr) is out of range for $(nvariants) variants")
        counts[idx] += 1
    end
    return counts
end

function read_col_data(
    sock::ClickHouseSock,
    num_rows::VarUInt,
    ::Val{:Variant},
    ast::TypeAst,
    args::TypeAst...,
)
    state = ast.state isa VariantState ? ast.state : VariantState(VARIANT_DISCRIMINATORS_BASIC)
    discriminators = read_variant_discriminators(sock, num_rows, state)
    counts = variant_counts(discriminators, length(args))
    columns = Vector{AbstractVector}(undef, length(args))
    for i in eachindex(args)
        columns[i] = read_col_data(sock, VarUInt(counts[i]), args[i])
    end

    T = variant_union_type(args...)
    result = Vector{T}(undef, length(discriminators))
    offsets = ones(Int, length(args))
    for i in eachindex(discriminators)
        discr = discriminators[i]
        if discr == VARIANT_NULL_DISCRIMINATOR
            result[i] = missing
        else
            idx = Int(discr) + 1
            value = columns[idx][offsets[idx]]
            offsets[idx] += 1
            result[i] = ClickHouseVariant{idx}(value)
        end
    end
    return result
end

function variant_input_index(value, nested_types)
    matches = Int[]
    for i in eachindex(nested_types)
        value isa nested_types[i] && push!(matches, i)
    end
    length(matches) == 1 ||
        throw(ArgumentError(
            "Variant value $(value) matched $(length(matches)) alternatives; use ClickHouseVariant{I}(value)"
        ))
    return matches[1]
end

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector,
    ::Val{:Variant},
    ast::TypeAst,
    args::TypeAst...,
)
    length(args) <= 255 ||
        throw(ArgumentError("Variant cannot have more than 255 nested types"))
    nested_types = [remove_vector_type(result_type(arg)) for arg in args]
    nested_values = [T[] for T in nested_types]
    discriminators = Vector{UInt8}(undef, length(data))

    for (row, value) in pairs(data)
        if ismissing(value)
            discriminators[row] = VARIANT_NULL_DISCRIMINATOR
            continue
        end

        idx = if value isa ClickHouseVariant
            Int(typeof(value).parameters[1])
        else
            variant_input_index(value, nested_types)
        end
        1 <= idx <= length(args) ||
            throw(ArgumentError("Variant index $(idx) is out of range"))

        payload = value isa ClickHouseVariant ? value.value : value
        push!(nested_values[idx], payload)
        discriminators[row] = UInt8(idx - 1)
    end

    chwrite(sock, discriminators)
    for i in eachindex(args)
        write_col_data(sock, nested_values[i], args[i])
    end
    return nothing
end

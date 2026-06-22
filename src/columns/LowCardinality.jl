using UUIDs

is_ch_type(::Val{:LowCardinality})  = true
can_be_nullable(::Val{:LowCardinality}) = false

# Need to read additional keys.
# Additional keys are stored before indexes as value N and N keys
# after them.
const lc_has_additional_keys_bit = 1 << 9
# Need to update dictionary.
# It means that previous granule has different dictionary.
const lc_need_update_dictionary = 1 << 10

const lc_serialization_type = lc_has_additional_keys_bit | lc_need_update_dictionary

const lc_index_int_types = [:UInt8, :UInt16, :UInt32, :UInt64]

categorical_vector_type(::Type{Vector{T}}) where {T} =
                                                 CategoricalVector{T}
categorical_vector_type(::Type{CategoricalVector{T}}) where {T} =
                                                CategoricalVector{T}

result_type(::Val{:LowCardinality}, nested)  =
                             categorical_vector_type(result_type(nested))

function lc_index_int_type(max_key::Integer)
    max_key < 0 && throw(ArgumentError("LowCardinality key cannot be negative"))
    max_key <= typemax(UInt8) && return 0
    max_key <= typemax(UInt16) && return 1
    max_key <= typemax(UInt32) && return 2
    return 3
end

function read_state_prefix(sock::ClickHouseSock, ::Val{:LowCardinality}, nested::TypeAst)
    ver = chread(sock, UInt64) # KeysSerializationVersion
    ver == 1 || error("unsupported LC serialization version: $(ver)")
    return ver
end

function write_state_prefix(sock::ClickHouseSock, ::Val{:LowCardinality}, nested::TypeAst)
    # KeysSerializationVersion. See ClickHouse docs.
    chwrite(sock, Int64(1))
end

function make_result(index::Vector{T}, keys, is_nullable) where {T}

    result = is_nullable ?
            CategoricalVector{Union{T, Missing}}(undef, 0, levels = index)  :
            CategoricalVector{T}(undef, 0, levels = index)
    result.refs = keys
    return result
end

function make_result(index::CategoricalVector{T}, keys, is_nullable) where {T}

    result = is_nullable ?
            CategoricalVector{Union{T, Missing}}(undef, 0, levels = unwrap.(index))  :
            CategoricalVector{T}(undef, 0, levels = unwrap.(index))
    result.refs = keys
    return result
end

function low_cardinality_refs(keys, nlevels::Integer, is_nullable::Bool)::Vector{UInt32}
    nlevels >= 0 || throw(ArgumentError("LowCardinality dictionary size cannot be negative"))
    nlevels <= typemax(UInt32) ||
        throw(ArgumentError("LowCardinality dictionary has too many keys: $(nlevels)"))

    max_ref = UInt64(nlevels)
    refs = Vector{UInt32}(undef, length(keys))
    if is_nullable
        for i in eachindex(keys)
            key = UInt64(keys[i])
            key <= max_ref ||
                throw(ArgumentError(
                    "LowCardinality key $(key) exceeds dictionary size $(nlevels)",
                ))
            refs[i] = UInt32(key)
        end
    else
        for i in eachindex(keys)
            key = UInt64(keys[i])
            key < max_ref ||
                throw(ArgumentError(
                    "LowCardinality key $(key) exceeds dictionary size $(nlevels)",
                ))
            refs[i] = UInt32(key + 1)
        end
    end
    return refs
end


function read_col_data(sock::ClickHouseSock, num_rows::VarUInt,
                                            ::Val{:LowCardinality}, nested::TypeAst)

    UInt64(num_rows)  == 0 && return read_col_data(sock, num_rows, nested)

    is_nested_nullable = (nested.name == :Nullable)
    notnullable_nested = is_nested_nullable ? nested.args[1] : nested

    serialization_type = chread(sock, UInt64)
    int_type = serialization_type & 0xf
    int_type <= 3 || error("unsupported LowCardinality key type: $(int_type)")

    index_size = chread(sock, UInt64)
    index = read_col_data(sock, VarUInt(index_size), notnullable_nested)
    if is_nested_nullable
        !isempty(index) ||
            throw(ArgumentError("LowCardinality(Nullable(T)) dictionary is missing null entry"))
        index = index[2:end]
    end

    keys_size = chread(sock, UInt64)
    keys_size == UInt64(num_rows) ||
        throw(ArgumentError(
            "LowCardinality key count $(keys_size) does not match row count $(UInt64(num_rows))",
        ))
    keys = read_col_data(sock, VarUInt(keys_size), Val(lc_index_int_types[int_type + 1]))
    refs = low_cardinality_refs(keys, length(index), is_nested_nullable)


    return make_result(index, refs, nested.name == :Nullable)
end


unmissing_type(::Type{Union{Missing, T}}) where {T} = T
unmissing_type(::Type{T}) where {T} = T

function write_col_data(sock::ClickHouseSock,
                                data::AbstractCategoricalVector{T},
                                ::Val{:LowCardinality}, nested::TypeAst) where {T}

    is_nested_nullable = (nested.name == :Nullable)
    notnullable_nested = is_nested_nullable ? nested.args[1] : nested

    isempty(data) && return

    max_key = is_nested_nullable ? length(levels(data)) : length(levels(data)) - 1
    int_type = lc_index_int_type(max_key)

    serialization_type = lc_serialization_type | int_type
    chwrite(sock, serialization_type)

    index = is_nested_nullable ?
                    vcat(missing_replacement(unmissing_type(T)), levels(data)) :
                    levels(data)

    chwrite(sock, length(index))
    write_col_data(sock, index, notnullable_nested)

    chwrite(sock, length(data))

    #In c++ indexes started from 0, in case of nullable nested 0 means null and
    # it's ok, but if nested not nullable we must sub 1 from index
    keys = is_nested_nullable ? data.refs : data.refs .- 1
    write_col_data(sock, keys, Val(lc_index_int_types[int_type + 1]))
end

function write_col_data(sock::ClickHouseSock,
                                data::AbstractVector{T},
                                v::Val{:LowCardinality}, nested::TypeAst) where {T}
    write_col_data(sock, CategoricalVector{T}(data), v, nested)
end

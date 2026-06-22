is_ch_type(::Val{:Map}) = true
can_be_nullable(::Val{:Map}) = false

function map_tuple_ast(key::TypeAst, value::TypeAst)
    ast = TypeAst(:Tuple)
    push!(ast, key)
    push!(ast, value)
    return ast
end

map_input_type(::Type{CategoricalValue{T}}) where {T} = T
map_input_type(::Type{T}) where {T} = T

function map_pair_type(key::TypeAst, value::TypeAst)
    K = remove_vector_type(result_type(key))
    V = remove_vector_type(result_type(value))
    return Pair{K, V}
end

result_type(::Val{:Map}, key::TypeAst, value::TypeAst) =
    Vector{Vector{map_pair_type(key, value)}}

function read_col_data(
    sock::ClickHouseSock,
    num_rows::VarUInt,
    ::Val{:Map},
    key::TypeAst,
    value::TypeAst,
)
    UInt64(num_rows) == 0 && return result_type(Val(:Map), key, value)(undef, 0)

    rows = read_col_data(sock, num_rows, Val(:Array), map_tuple_ast(key, value))
    P = map_pair_type(key, value)
    result = Vector{Vector{P}}(undef, length(rows))
    for i in eachindex(rows)
        row = Vector{P}(undef, length(rows[i]))
        for j in eachindex(rows[i])
            k, v = rows[i][j]
            row[j] = k => v
        end
        result[i] = row
    end
    return result
end

map_entries(row::AbstractDict) = pairs(row)
map_entries(row::AbstractVector) = row
map_entries(row) =
    throw(ArgumentError("Map rows must be dictionaries or vectors of pairs/tuples, got $(typeof(row))"))

entry_key_value(entry::Pair) = (entry.first, entry.second)

function entry_key_value(entry::Tuple)
    length(entry) == 2 ||
        throw(ArgumentError("Map tuple entries must contain exactly 2 values"))
    return entry
end

entry_key_value(entry) =
    throw(ArgumentError("Map entries must be Pairs or 2-tuples, got $(typeof(entry))"))

function write_col_data(
    sock::ClickHouseSock,
    data::AbstractVector,
    ::Val{:Map},
    key::TypeAst,
    value::TypeAst,
)
    K = map_input_type(remove_vector_type(result_type(key)))
    V = map_input_type(remove_vector_type(result_type(value)))
    rows = Vector{Vector{Tuple{K, V}}}(undef, length(data))

    for i in eachindex(data)
        entries = map_entries(data[i])
        row = Vector{Tuple{K, V}}()
        sizehint!(row, length(entries))
        for entry in entries
            k, v = entry_key_value(entry)
            push!(row, (convert(K, k), convert(V, v)))
        end
        rows[i] = row
    end

    write_col_data(sock, rows, Val(:Array), map_tuple_ast(key, value))
    return nothing
end

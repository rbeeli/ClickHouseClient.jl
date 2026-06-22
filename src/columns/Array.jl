is_ch_type(::Val{:Array})  = true
can_be_nullable(::Val{:Array}) = false
result_type(::Val{:Array}, nested::TypeAst) = Vector{result_type(nested)}

"""
    Nested arrays written in flatten form after information about their
    sizes (offsets really).
    One element of array of arrays can be represented as tree:
    (0 depth)          [[3, 4], [5, 6]]
                      |               |
    (1 depth)      [3, 4]           [5, 6]
                   |    |           |    |
    (leaf)        3     4          5     6

    Offsets (sizes) written in breadth-first search order. In example above
    following sequence of offset will be written: 4 -> 2 -> 4
    1) size of whole array: 4
    2) size of array 1 in depth=1: 2
    3) size of array 2 plus size of all array before in depth=1: 2 + 2 = 4

    After sizes info comes flatten data: 3 -> 4 -> 5 -> 6
"""

read_state_prefix(sock::ClickHouseSock, ::Val{:Array}, nested::TypeAst) =
                    read_state_prefix(sock, nested)

write_state_prefix(sock::ClickHouseSock, ::Val{:Array}, nested::TypeAst) =
                write_state_prefix(sock, nested)

function validate_array_offsets(offsets::Vector{UInt64}, what::AbstractString)::UInt64
    last_offset = UInt64(0)
    for offset in offsets
        offset >= last_offset ||
            throw(ArgumentError("ClickHouse $(what) offsets are not monotonic"))
        last_offset = offset
    end
    return last_offset
end

function read_offsets!(dest::Vector{Vector{UInt64}}, sock, nest::TypeAst)
    prev_level = dest[end]
    count = validate_array_offsets(prev_level, "parent")
    len = checked_vector_length(sock, count, UInt64)
    new_level = Vector{UInt64}(undef, len)
    last_offset = UInt64(0)
    for i in eachindex(new_level)
        offset = chread(sock, UInt64)
        offset >= last_offset ||
            throw(ArgumentError("ClickHouse Array offsets are not monotonic"))
        new_level[i] = offset
        last_offset = offset
    end
    push!(dest, new_level)

    return nest.name == :Array ?
        read_offsets!(dest, sock, nest.args[1]) :
        nest

end

function split_vector(data::T, offsets) where {T <: AbstractVector}
    result = Vector{T}(undef, length(offsets))
    data_len = UInt64(length(data))
    last_offset = UInt64(0)
    for (i,offset) in enumerate(offsets)
        offset >= last_offset ||
            throw(ArgumentError("ClickHouse Array offsets are not monotonic"))
        offset <= data_len ||
            throw(ArgumentError(
                "ClickHouse Array offset $(offset) exceeds nested data length $(data_len)",
            ))
        result[i] = data[Int(last_offset) + 1:Int(offset)]
        last_offset = offset
    end
    return result
end

function read_col_data(sock::ClickHouseSock, num_rows::VarUInt,
                                            ::Val{:Array}, nest::TypeAst)

    (UInt64(num_rows) == 0) && return result_type(Val(:Array), nest)(undef, 0)

    size = UInt64(num_rows)
    checked_vector_length(sock, size, UInt64)

    offsets = [UInt64[size]]

    data_type = read_offsets!(offsets, sock, nest)

    data_size = isempty(offsets[end]) ? UInt64(0) : offsets[end][end]

    data = read_col_data(sock, VarUInt(data_size), data_type)

    result = data
    #top offset is the size of column, so we don't take it into account
    for off in Iterators.reverse(offsets[2:end])
        result = split_vector(result, off)
    end
    return result
end

const PossibleVectors{T} =
     Union{<:AbstractVector{T}, <:AbstractCategoricalVector{T}}
function get_base_type(
    ::Type{<:AbstractVector{T}},
    nest ::TypeAst,
) where {T}
    nest.name == :Array && return get_base_type(T, nest.args[1])
    return (T, nest)
end
function flatten_array!(offsets, itr, nest)
    new_level = UInt64[]
    last_offset = 0
    for part in itr
        push!(new_level, last_offset + length(part))
        last_offset = new_level[end]
    end
    push!(offsets, new_level)
    (nest.name != :Array) && return (Iterators.flatten(itr), nest)
    return flatten_array!(offsets, Iterators.flatten(itr), nest.args[1])

end

function array_leaf_eltype(::Type{<:AbstractVector{T}}, nest::TypeAst) where {T}
    nest.name == :Array && return array_leaf_eltype(T, nest.args[1])
    return T <: AbstractVector ? eltype(T) : Any
end

array_leaf_eltype(::Type{T}, ::TypeAst) where {T} = T

function ensure_offset_level!(offsets::Vector{Vector{UInt64}}, level::Int)::Vector{UInt64}
    while length(offsets) < level
        push!(offsets, UInt64[])
    end
    return offsets[level]
end

function append_array_offsets_values!(
    offsets::Vector{Vector{UInt64}},
    values::Vector{T},
    rows,
    nest::TypeAst,
    level::Int,
)::Nothing where {T}
    level_offsets = ensure_offset_level!(offsets, level)
    last_offset = isempty(level_offsets) ? UInt64(0) : level_offsets[end]

    if nest.name == :Array
        for row in rows
            last_offset += UInt64(length(row))
            push!(level_offsets, last_offset)
        end
        for row in rows
            append_array_offsets_values!(offsets, values, row, nest.args[1], level + 1)
        end
    else
        for row in rows
            last_offset += UInt64(length(row))
            push!(level_offsets, last_offset)
            for value in row
                push!(values, value)
            end
        end
    end

    return nothing
end

function write_col_data(sock::ClickHouseSock,
                                data::AbstractVector{T},
                                ::Val{:Array}, nest::TypeAst) where {T}

    offsets = Vector{Vector{UInt64}}()
    leaf_type = array_leaf_eltype(typeof(data), nest)
    values = Vector{leaf_type}()
    append_array_offsets_values!(offsets, values, data, nest, 1)

    for level_offsets in offsets
        chwrite(sock, level_offsets)
    end
    base_ast = nest
    while base_ast.name == :Array
        base_ast = base_ast.args[1]
    end
    write_col_data(sock, values, base_ast)
end

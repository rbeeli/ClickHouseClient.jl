is_ch_type(::Val{:Enum8})  = true
is_ch_type(::Val{:Enum16})  = true
result_type(::Val{:Enum8}, args...)  = CategoricalVector{String}
result_type(::Val{:Enum16}, args...)  = CategoricalVector{String}

const ENUM_RE_ARG = r"""

           '((?:(?:[^'])|(?:\\'))*)'
           \s*=\s*
           (-?\d+)
           \s*$
       """x

function unescape_enum_label(label::AbstractString)::String
    io = IOBuffer()
    escaped = false
    for c in label
        if escaped
            if c == 'b'
                print(io, '\b')
            elseif c == 'f'
                print(io, '\f')
            elseif c == 'n'
                print(io, '\n')
            elseif c == 'r'
                print(io, '\r')
            elseif c == 't'
                print(io, '\t')
            elseif c == '0'
                print(io, '\0')
            else
                print(io, c)
            end
            escaped = false
        elseif c == '\\'
            escaped = true
        else
            print(io, c)
        end
    end
    escaped && error("Trailing escape in enum label $(repr(label))")
    return String(take!(io))
end

function enum_entries(::Type{BaseT}, args...) where {BaseT}
    entries = Pair{String, BaseT}[]
    seen_labels = Set{String}()
    seen_values = Set{BaseT}()
    for arg in args
        m = match(ENUM_RE_ARG, arg)
        isnothing(m) && error("Wrong enum argument $arg")
        label = unescape_enum_label(m.captures[1])
        value = parse(BaseT, m.captures[2])
        label in seen_labels && error("Duplicate enum label: $(repr(label))")
        value in seen_values && error("Duplicate enum value: $(value)")
        push!(seen_labels, label)
        push!(seen_values, value)
        push!(entries, label => value)
    end
    return entries
end

make_enum_map(::Type{BaseT}, args...) where {BaseT} =
    Dict(enum_entries(BaseT, args...))

function read_enum_data(sock::ClickHouseSock, num_rows::VarUInt,
                                        ::Type{BaseT}, args...) where {BaseT}
    entries = enum_entries(BaseT, args...)
    levels = String[first(entry) for entry in entries]
    enum_to_level = Dict(last(entry) => UInt32(i) for (i, entry) in pairs(entries))
    data = chread(sock, Vector{BaseT}, num_rows)
    refs = Vector{UInt32}(undef, length(data))
    for i in eachindex(data)
        level = get(enum_to_level, data[i], nothing)
        level === nothing &&
            throw(ArgumentError("Unknown enum value $(data[i])"))
        refs[i] = level
    end
    result = CategoricalVector{String}(undef, 0, levels = levels)
    result.refs = refs
    return result
end

function write_enum_data(sock::ClickHouseSock, data::AbstractVector{String},
                                        ::Type{BaseT}, args...) where {BaseT}
    map = make_enum_map(BaseT, args...)
    d = Vector{BaseT}(undef, length(data))
    try
        d .= getindex.(Ref(map), data)
    catch exc
        if exc isa KeyError
            error("Value is not a valid enum variant: $(exc.key)")
        end
        rethrow()
    end
    chwrite(sock, d)
end

function write_enum_data(sock::ClickHouseSock, data::CategoricalVector{String},
                                        ::Type{BaseT}, args...) where {BaseT}
    map = make_enum_map(BaseT, args...)
    try

        level_to_enum = getindex.(Ref(map), levels(data))
        d = convert(Vector{BaseT}, getindex.(Ref(level_to_enum), data.refs))
        chwrite(sock, d)

    catch exc
        if exc isa KeyError
            error("Value is not a valid enum variant: $(exc.key)")
        end
        rethrow()
    end


end

read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ::Val{:Enum8}, args...) =
                     read_enum_data(sock, num_rows, Int8, args...)
read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ::Val{:Enum16}, args...) =
                    read_enum_data(sock, num_rows, Int16, args...)


write_col_data(sock::ClickHouseSock,
        data::AbstractVector{String},
         ::Val{:Enum8},
         args...) = write_enum_data(sock, data, Int8, args...)

write_col_data(sock::ClickHouseSock,
                data::AbstractVector{String},
                ::Val{:Enum16},
                 args...) = write_enum_data(sock, data, Int16, args...)

write_col_data(sock::ClickHouseSock,
             data::CategoricalVector{String},
             ::Val{:Enum8},
             args...) = write_enum_data(sock, data, Int8, args...)

write_col_data(sock::ClickHouseSock,
            data::CategoricalVector{String},
            ::Val{:Enum16}, args...) =
            write_enum_data(sock, data, Int16, args...)

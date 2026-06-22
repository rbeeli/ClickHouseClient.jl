import Tables
import Sockets


# ============================================================================ #
# [Helpers]                                                                    #
# ============================================================================ #

"""
    ExternalTable(name, columns)
    ExternalTable(name, block)

External temporary table sent with a query through `QueryOptions`.
`columns` is a vector of `Column` values whose names, ClickHouse type strings,
and vectors define the temporary table data.
"""
struct ExternalTable
    name::String
    columns::Vector{Column}
end

ExternalTable(name::AbstractString, columns::Vector{Column}) =
    ExternalTable(String(name), columns)

ExternalTable(name::AbstractString, block::Block) =
    ExternalTable(String(name), block.columns)

function normalize_query_settings(settings::QuerySettings)::QuerySettings
    return settings
end

normalize_query_settings(::Nothing) = QuerySettings()

function normalize_query_settings(settings::AbstractDict)::QuerySettings
    return QuerySettings(QuerySetting[
        QuerySetting(string(name), value)
        for (name, value) in settings
    ])
end

function normalize_query_settings(settings::NamedTuple)::QuerySettings
    return QuerySettings(QuerySetting[
        QuerySetting(string(name), value)
        for (name, value) in pairs(settings)
    ])
end

function normalize_query_settings(settings::AbstractVector{QuerySetting})::QuerySettings
    return QuerySettings(settings)
end

function normalize_query_settings(settings::AbstractVector{<:Pair})::QuerySettings
    return QuerySettings(QuerySetting[
        QuerySetting(string(name), value)
        for (name, value) in settings
    ])
end

function normalize_query_settings(settings::Tuple)::QuerySettings
    all(x -> x isa QuerySetting || x isa Pair, settings) ||
        throw(ArgumentError("settings tuples must contain QuerySetting or Pair values"))
    return QuerySettings(QuerySetting[
        x isa QuerySetting ? x : QuerySetting(string(first(x)), last(x))
        for x in settings
    ])
end

function clickhouse_string_field_dump(value)::String
    io = IOBuffer()
    print(io, "'")
    for c in string(value)
        if c == '\''
            print(io, "\\'")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\b'
            print(io, "\\b")
        elseif c == '\f'
            print(io, "\\f")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c == '\0'
            print(io, "\\0")
        else
            print(io, c)
        end
    end
    print(io, "'")
    return String(take!(io))
end

query_parameter_setting(name, value)::QuerySetting =
    QuerySetting(
        string(name),
        clickhouse_string_field_dump(value),
        VarUInt(SETTINGS_FLAG_CUSTOM),
    )

function normalize_query_parameters(parameters::QuerySettings)::QuerySettings
    return parameters
end

normalize_query_parameters(::Nothing) = QuerySettings()

function normalize_query_parameters(parameters::AbstractDict)::QuerySettings
    return QuerySettings(QuerySetting[
        query_parameter_setting(name, value)
        for (name, value) in parameters
    ])
end

function normalize_query_parameters(parameters::NamedTuple)::QuerySettings
    return QuerySettings(QuerySetting[
        query_parameter_setting(name, value)
        for (name, value) in pairs(parameters)
    ])
end

function normalize_query_parameters(parameters::AbstractVector{QuerySetting})::QuerySettings
    return QuerySettings(parameters)
end

function normalize_query_parameters(parameters::AbstractVector{<:Pair})::QuerySettings
    return QuerySettings(QuerySetting[
        query_parameter_setting(name, value)
        for (name, value) in parameters
    ])
end

function normalize_query_parameters(parameters::Tuple)::QuerySettings
    all(x -> x isa QuerySetting || x isa Pair, parameters) ||
        throw(ArgumentError("parameter tuples must contain QuerySetting or Pair values"))
    return QuerySettings(QuerySetting[
        x isa QuerySetting ? x : query_parameter_setting(first(x), last(x))
        for x in parameters
    ])
end

normalize_external_tables(::Nothing) = ExternalTable[]
normalize_external_tables(tables::AbstractVector{ExternalTable}) = collect(tables)
normalize_external_tables(tables::Tuple) = ExternalTable[table for table in tables]

normalize_external_roles(::Nothing) = String[]
normalize_external_roles(roles) = String[String(role) for role in roles]

function quote_identifier_part(part::AbstractString)::String
    text = String(part)
    isempty(text) && throw(ArgumentError("Identifier parts must not be empty"))
    occursin('\0', text) &&
        throw(ArgumentError("Identifier parts must not contain NUL bytes"))
    occursin('`', text) &&
        throw(ArgumentError("Identifier parts containing backticks are not supported"))
    return "`$(text)`"
end

function table_identifier(table::AbstractString)::String
    text = strip(String(table))
    isempty(text) && throw(ArgumentError("Table identifier must not be empty"))
    parts = split(text, '.'; keepempty = true)
    1 <= length(parts) <= 2 ||
        throw(ArgumentError("Table identifiers must be table or database.table"))
    return join(quote_identifier_part.(parts), ".")
end

function table_identifier(table::TableRef)::String
    if isempty(table.database)
        return quote_identifier_part(table.table)
    end
    return "$(quote_identifier_part(table.database)).$(quote_identifier_part(table.table))"
end

function serialized_string_vector(values::Vector{String})::String
    io = IOBuffer(read = true, write = true)
    scratch = ClickHouseSock(io)
    chwrite(scratch, VarUInt(length(values)))
    foreach(value -> chwrite(scratch, value), values)
    return String(take!(io))
end

"""
    QueryOptions(; query_id="", settings=nothing, parameters=nothing,
                   quota_key="", stage=QUERY_STAGE_COMPLETE,
                   compression=nothing, opentelemetry=nothing,
                   external_tables=nothing, external_roles=nothing)

Per-query native protocol options accepted by `execute`, `insert`,
`insert_records`, `query`, `select_df`, `select_channel`, and
`select_callback`.

`settings` and `parameters` accept dictionaries, named tuples, pairs,
`QuerySetting` vectors, or `QuerySettings`. Query parameters are referenced in
SQL as `{name:Type}`. `compression` overrides the socket default for this
query, and `external_tables` sends temporary table blocks before execution.
"""
struct QueryOptions
    query_id::String
    settings::QuerySettings
    parameters::QuerySettings
    quota_key::String
    stage::QueryStage
    compression::Union{Nothing, Compression}
    opentelemetry::Union{Nothing, OpenTelemetryContext}
    external_tables::Vector{ExternalTable}
    external_roles::Vector{String}
end

function QueryOptions(;
    query_id::AbstractString = "",
    settings = nothing,
    parameters = nothing,
    quota_key::AbstractString = "",
    stage::QueryStage = QUERY_STAGE_COMPLETE,
    compression::Union{Nothing, Compression} = nothing,
    opentelemetry::Union{Nothing, OpenTelemetryContext} = nothing,
    external_tables = nothing,
    external_roles = nothing,
)
    return QueryOptions(
        String(query_id),
        normalize_query_settings(settings),
        normalize_query_parameters(parameters),
        String(quota_key),
        stage,
        compression,
        opentelemetry,
        normalize_external_tables(external_tables),
        normalize_external_roles(external_roles),
    )
end

query_compression(sock::ClickHouseSock, options::QueryOptions)::Compression =
    isnothing(options.compression) ? sock.settings.compression : options.compression

function finish_query!(sock::ClickHouseSock)::Nothing
    sock.query_compression = nothing
    return nothing
end

function make_client_info(sock::ClickHouseSock, options::QueryOptions)::ClientInfo
    return ClientInfo(
        query_id = options.query_id,
        initial_user = sock.settings.username,
        quota_key = options.quota_key,
        opentelemetry = options.opentelemetry,
    )
end

function write_external_tables(sock::ClickHouseSock, tables::Vector{ExternalTable})::Nothing
    for table in tables
        write_packet(sock, make_block(table.columns; temp_table = table.name); flush = false)
    end
    write_packet(sock, make_block())
    return nothing
end

function write_query(
    sock::ClickHouseSock,
    query::AbstractString;
    options::QueryOptions = QueryOptions(),
)::Nothing
    compression = query_compression(sock, options)
    query = ClientQuery(
        options.query_id,
        make_client_info(sock, options),
        options.settings,
        serialized_string_vector(options.external_roles),
        "",
        query_stage_value(options.stage),
        VarUInt(compression != COMPRESSION_NONE),
        String(query),
        options.parameters,
    )
    write_packet(sock, query)
    sock.query_compression = compression
    write_external_tables(sock, options.external_tables)
    return nothing
end

function dict2columns(
    dict::AbstractDict{Symbol, T} where T,
    valid_columns::Dict{Symbol, String},
)::Vector{Column}
    diff = symdiff(Set(keys(dict)), Set(keys(valid_columns)))
    if !isempty(diff)
        throw(ArgumentError("Mismatched columns: $(collect(diff))"))
    end

    # TODO: Check if column types match.

    Column[
        Column(string(name), valid_columns[name], column)
        for (name, column) ∈ dict
    ]
end

struct InsertColumnsSpec
    names::Vector{Symbol}
    types::Vector{String}
    asts::Vector{TypeAst}
    lookup::Dict{Symbol, Int}
    name_set::Set{Symbol}
end

function InsertColumnsSpec(columns::Vector{Column})
    names = Symbol[Symbol(column.name) for column in columns]
    types = String[column.type for column in columns]
    asts = TypeAst[parse_typestring(type) for type in types]
    lookup = Dict{Symbol, Int}()
    for (i, name) in pairs(names)
        haskey(lookup, name) &&
            throw(ArgumentError("Duplicate insert column name: $(name)"))
        lookup[name] = i
    end
    return InsertColumnsSpec(names, types, asts, lookup, Set(names))
end

Base.length(spec::InsertColumnsSpec) = length(spec.names)

function insert_scalar_type(ast::TypeAst)
    name = ast.name
    if name == :Nullable
        return Union{Missing, insert_scalar_type(ast.args[1])}
    elseif name == :LowCardinality
        return insert_scalar_type(ast.args[1])
    elseif name == :SimpleAggregateFunction
        return insert_scalar_type(ast.args[2])
    elseif name == :Enum8 || name == :Enum16 || name == :FixedString
        return String
    elseif name == :DateTime
        return DateTime
    elseif name == :DateTime64
        return DateTime64{parse_datetime64_precision(ast.args[1])}
    elseif name == :Time
        return ClickHouseTime
    elseif name == :Time64
        return ClickHouseTime64{parse_time64_precision(ast.args[1])}
    elseif name == :Array
        return Vector{insert_scalar_type(ast.args[1])}
    elseif name == :Tuple
        return Tuple{insert_scalar_type.(ast.args)...}
    elseif name == :Map
        return Vector{insert_map_pair_type(ast.args[1], ast.args[2])}
    elseif name == :Variant
        return variant_insert_union_type(ast.args...)
    elseif name == :Dynamic
        return Union{Missing, AbstractClickHouseDynamic}
    elseif name == :JSON
        return JSON3.Object
    end
    return remove_vector_type(result_type(ast))
end

insert_vector_type(ast::TypeAst) = Vector{insert_scalar_type(ast)}

function insert_map_pair_type(key::TypeAst, value::TypeAst)
    return Pair{insert_scalar_type(key), insert_scalar_type(value)}
end

function variant_insert_union_type(args::TypeAst...)
    types = (Missing, (ClickHouseVariant{i, insert_scalar_type(args[i])} for i in eachindex(args))...)
    return Union{types...}
end

function decimal_insert_value(
    value,
    ::Type{DecimalT},
    ::Type{IntT},
    precision::Integer,
    scale::Integer,
    decfp_type,
    type_name::AbstractString,
) where {DecimalT <: AbstractClickHouseDecimal, IntT <: Integer}
    if value isa DecimalT
        decimal_scale(value) == scale ||
            throw(ArgumentError("Decimal:Wrong exponent in input data, expected $(scale)"))
        return DecimalT(decimal_raw_value(IntT, value.value, precision, type_name))
    elseif value isa AbstractClickHouseDecimal
        decimal_scale(value) == scale ||
            throw(ArgumentError("Decimal:Wrong exponent in input data, expected $(scale)"))
        return DecimalT(decimal_raw_value(IntT, value.value, precision, type_name))
    elseif value isa Integer
        return DecimalT(decimal_raw_value(IntT, value, precision, type_name))
    elseif decfp_type !== nothing
        sign, significand, exp = sigexp(convert(decfp_type, value))
        exp == -scale ||
            throw(ArgumentError(
                "Decimal:Wrong exponent in input data, expected $(scale) got $(exp)",
            ))
        return DecimalT(decimal_raw_value(IntT, sign * significand, precision, type_name))
    end

    throw(ArgumentError("Cannot convert $(typeof(value)) to $(DecimalT)"))
end

function convert_decimal_insert_value(value, ast::TypeAst)
    if ast.name == :Decimal
        precision, scale = length(ast.args) == 1 ?
            parse_decimal_parameters(ast.args[1]) :
            parse_decimal_parameters(ast.args[1], ast.args[2])
        concrete = dec_type_by_precision(ast.args[1])
        type_name = "Decimal($(precision),$(scale))"
    else
        concrete = ast.name
        scale = if concrete == :Decimal32
            parse_decimal_scale(ast.args[1], 9)
        elseif concrete == :Decimal64
            parse_decimal_scale(ast.args[1], 18)
        elseif concrete == :Decimal128
            parse_decimal_scale(ast.args[1], 38)
        elseif concrete == :Decimal256
            parse_decimal_scale(ast.args[1], 76)
        else
            throw(ArgumentError("Unsupported Decimal type $(concrete)"))
        end
        precision = decimal_precision(concrete)
        type_name = string(concrete)
    end

    if concrete == :Decimal32
        return decimal_insert_value(value, ClickHouseDecimal32{scale}, Int32, precision, scale, Dec32, type_name)
    elseif concrete == :Decimal64
        return decimal_insert_value(value, ClickHouseDecimal64{scale}, Int64, precision, scale, Dec64, type_name)
    elseif concrete == :Decimal128
        return decimal_insert_value(value, ClickHouseDecimal128{scale}, Int128, precision, scale, Dec128, type_name)
    elseif concrete == :Decimal256
        return decimal_insert_value(value, ClickHouseDecimal256{scale}, Int256, precision, scale, nothing, type_name)
    end

    throw(ArgumentError("Unsupported Decimal type $(concrete)"))
end

function convert_array_insert_value(value, nest::TypeAst)
    value isa AbstractVector ||
        throw(ArgumentError("Array values must be AbstractVector, got $(typeof(value))"))

    T = insert_scalar_type(nest)
    result = Vector{T}(undef, length(value))
    for i in eachindex(value)
        result[i] = convert_insert_value(value[i], nest)
    end
    return result
end

function convert_tuple_insert_value(value, args::TypeAst...)
    value isa Tuple ||
        throw(ArgumentError("Tuple values must be tuples, got $(typeof(value))"))
    length(value) == length(args) ||
        throw(ArgumentError("Tuple value has $(length(value)) fields, expected $(length(args))"))

    return ntuple(i -> convert_insert_value(value[i], args[i]), length(args))
end

function convert_map_insert_value(value, key::TypeAst, val::TypeAst)
    entries = map_entries(value)
    P = insert_map_pair_type(key, val)
    result = Vector{P}()
    sizehint!(result, length(entries))
    for entry in entries
        k, v = entry_key_value(entry)
        push!(result, convert_insert_value(k, key) => convert_insert_value(v, val))
    end
    return result
end

function make_insert_variant_value(idx::Integer, value, ast::TypeAst)
    T = insert_scalar_type(ast)
    return ClickHouseVariant{idx, T}(value)
end

function convert_variant_insert_value(value, args::TypeAst...)
    ismissing(value) && return missing

    if value isa ClickHouseVariant
        idx = Int(typeof(value).parameters[1])
        1 <= idx <= length(args) ||
            throw(ArgumentError("Variant index $(idx) is out of range"))
        payload = convert_insert_value(value.value, args[idx])
        return make_insert_variant_value(idx, payload, args[idx])
    end

    nested_types = [insert_scalar_type(arg) for arg in args]
    idx = variant_input_index(value, nested_types)
    payload = convert_insert_value(value, args[idx])
    return make_insert_variant_value(idx, payload, args[idx])
end

function convert_dynamic_insert_value(value)
    ismissing(value) && return missing

    result = value isa AbstractClickHouseDynamic ? value : ClickHouseDynamic(value)
    dynamic_ast_for_value(result.value)
    return result
end

convert_json_insert_value(value) = parse_json_object(json_string(value))

function convert_insert_value(value, ast::TypeAst)
    name = ast.name
    if name == :Nullable
        return ismissing(value) ? missing : convert_insert_value(value, ast.args[1])
    end
    if name == :Variant
        return convert_variant_insert_value(value, ast.args...)
    elseif name == :Dynamic
        return convert_dynamic_insert_value(value)
    end
    ismissing(value) &&
        throw(ArgumentError("Missing value cannot be inserted into non-Nullable $(name)"))

    if name == :LowCardinality
        return convert_insert_value(value, ast.args[1])
    elseif name == :SimpleAggregateFunction
        return convert_insert_value(value, ast.args[2])
    elseif name == :Enum8 || name == :Enum16 || name == :FixedString || name == :String
        return String(value)
    elseif name == :DateTime
        value isa TimeZones.ZonedDateTime && return utc_datetime(value)
        return convert(DateTime, value)
    elseif name == :DateTime64
        precision = parse_datetime64_precision(ast.args[1])
        value isa Integer && return DateTime64(value, precision)
        return DateTime64(datetime64_ticks(value, precision), precision)
    elseif name == :Time
        value isa ClickHouseTime && return value
        value isa Time && return ClickHouseTime(value)
    elseif name == :Time64
        precision = parse_time64_precision(ast.args[1])
        value isa ClickHouseTime64{precision} && return value
        value isa Time && return ClickHouseTime64(value, precision)
    elseif name == :Decimal || name == :Decimal32 || name == :Decimal64 ||
            name == :Decimal128 || name == :Decimal256
        return convert_decimal_insert_value(value, ast)
    elseif name == :Array
        return convert_array_insert_value(value, ast.args[1])
    elseif name == :Tuple
        return convert_tuple_insert_value(value, ast.args...)
    elseif name == :Map
        return convert_map_insert_value(value, ast.args[1], ast.args[2])
    elseif name == :JSON
        return convert_json_insert_value(value)
    end

    return convert(insert_scalar_type(ast), value)
end

function make_record_batch(spec::InsertColumnsSpec)::Vector{AbstractVector}
    batch = Vector{AbstractVector}(undef, length(spec))
    for i in eachindex(spec.asts)
        batch[i] = insert_vector_type(spec.asts[i])()
    end
    return batch
end

function sizehint_record_batch!(
    batch::Vector{AbstractVector},
    capacity::Integer,
)::Vector{AbstractVector}
    capacity < 0 && throw(ArgumentError("capacity must be non-negative"))
    for column in batch
        sizehint!(column, capacity)
    end
    return batch
end

function reset_record_batch!(batch::Vector{AbstractVector})::Nothing
    foreach(empty!, batch)
    return nothing
end

record_key_symbol(key::Symbol) = key
record_key_symbol(key::AbstractString) = Symbol(key)
record_key_symbol(key) =
    throw(ArgumentError("Record keys must be Symbols or strings, got $(typeof(key))"))

function record_column_names(record::AbstractDict)::Vector{Symbol}
    names = Symbol[]
    seen = Set{Symbol}()
    for key in keys(record)
        name = record_key_symbol(key)
        if name in seen
            throw(ArgumentError("Duplicate record key after normalization: $(name)"))
        end
        push!(seen, name)
        push!(names, name)
    end
    return names
end

function record_column_names(record)::Vector{Symbol}
    names = Symbol[]
    seen = Set{Symbol}()
    for key in Tables.columnnames(record)
        name = Symbol(key)
        if name in seen
            throw(ArgumentError("Duplicate record key after normalization: $(name)"))
        end
        push!(seen, name)
        push!(names, name)
    end
    return names
end

record_value(record::AbstractDict{Symbol}, name::Symbol) = record[name]

function record_value(record::AbstractDict, name::Symbol)
    haskey(record, name) && return record[name]
    string_name = String(name)
    haskey(record, string_name) && return record[string_name]

    for (key, value) in record
        record_key_symbol(key) == name && return value
    end
    throw(KeyError(name))
end

record_value(record, name::Symbol) = Tables.getcolumn(record, name)

function validate_record_columns(
    record,
    valid_column_names::Set{Symbol},
)::Nothing
    diff = symdiff(Set(record_column_names(record)), valid_column_names)
    if !isempty(diff)
        throw(ArgumentError("Mismatched record columns: $(collect(diff))"))
    end
    return nothing
end

function validate_block_columns(block, spec::InsertColumnsSpec)::Nothing
    diff = symdiff(Set(record_column_names(block)), spec.name_set)
    if !isempty(diff)
        throw(ArgumentError("Mismatched columns: $(collect(diff))"))
    end
    return nothing
end

function block_column(block, name::Symbol)::AbstractVector
    value = record_value(block, name)
    value isa AbstractVector ||
        throw(ArgumentError("Column $(name) must be an AbstractVector, got $(typeof(value))"))
    return value
end

function block_columns(block, spec::InsertColumnsSpec)::Vector{Column}
    validate_block_columns(block, spec)
    return Column[
        Column(String(spec.names[i]), spec.types[i], block_column(block, spec.names[i]))
        for i in eachindex(spec.names)
    ]
end

function push_record_value!(vec::Nothing, value)::AbstractVector
    return typeof(value)[value]
end

function push_record_value!(vec::AbstractVector{T}, value)::AbstractVector where {T}
    if value isa T
        push!(vec, value)
        return vec
    end

    U = Base.promote_typejoin(T, typeof(value))
    widened = Vector{U}(undef, length(vec) + 1)
    copyto!(widened, 1, vec, 1, length(vec))
    widened[end] = value
    return widened
end

function push_record!(
    batch::Dict{Symbol, AbstractVector},
    record,
    valid_column_names::Set{Symbol},
    column_names::Vector{Symbol},
    ;
    validate::Bool = true,
)::Nothing
    validate && validate_record_columns(record, valid_column_names)

    for name in column_names
        batch[name] = push_record_value!(get(batch, name, nothing), record_value(record, name))
    end
    return nothing
end

function push_record!(
    batch::Vector{AbstractVector},
    record,
    spec::InsertColumnsSpec;
    validate::Bool = true,
)::Nothing
    validate && validate_record_columns(record, spec.name_set)

    for i in eachindex(spec.names)
        push!(batch[i], convert_insert_value(record_value(record, spec.names[i]), spec.asts[i]))
    end
    return nothing
end

const DIRECT_RECORD_STAGING_TYPES = Set([
    :Bool,
    :UInt8,
    :UInt16,
    :UInt32,
    :UInt64,
    :UInt128,
    :UInt256,
    :Int8,
    :Int16,
    :Int32,
    :Int64,
    :Int128,
    :Int256,
    :BFloat16,
    :Float32,
    :Float64,
])

const STRING_RECORD_STAGING_TYPES = Set([
    :String,
    :FixedString,
    :Enum8,
    :Enum16,
])

const DATE_RECORD_STAGING_TYPES = Set([
    :Date,
    :Date32,
])

function record_staging_action(ast::TypeAst)::Symbol
    name = ast.name
    if name == :Nullable || name == :LowCardinality
        return record_staging_action(ast.args[1])
    elseif name == :SimpleAggregateFunction
        return record_staging_action(ast.args[2])
    end
    name in DIRECT_RECORD_STAGING_TYPES && return :direct
    name in STRING_RECORD_STAGING_TYPES && return :string
    name in DATE_RECORD_STAGING_TYPES && return :date
    name == :DateTime && return :datetime
    return :convert
end

direct_record_staging(ast::TypeAst)::Bool = record_staging_action(ast) == :direct
fast_record_staging(ast::TypeAst)::Bool = record_staging_action(ast) != :convert

nonmissing_field_type(::Type{Missing}) = Missing
nonmissing_field_type(::Type{Union{Missing, T}}) where {T} = T
nonmissing_field_type(::Type{T}) where {T} = T
direct_string_field(::Type{T}) where {T} =
    nonmissing_field_type(T) <: AbstractString
direct_date_field(::Type{T}) where {T} = nonmissing_field_type(T) <: Date
direct_datetime_field(::Type{T}) where {T} = nonmissing_field_type(T) <: DateTime

record_string_value(value) = ismissing(value) ? missing : String(value)
record_date_value(value) = ismissing(value) ? missing : convert(Date, value)
record_datetime_value(value) = ismissing(value) ? missing : convert(DateTime, value)
record_datetime_value(value::TimeZones.ZonedDateTime) = utc_datetime(value)

function namedtuple_field_indices(
    names::Tuple,
    spec::InsertColumnsSpec;
    validate::Bool,
)::Tuple
    normalized = Symbol.(names)
    if validate
        diff = symdiff(Set(normalized), spec.name_set)
        if !isempty(diff)
            throw(ArgumentError("Mismatched record columns: $(collect(diff))"))
        end
    end

    indices = Vector{Int}(undef, length(spec.names))
    for i in eachindex(spec.names)
        idx = findfirst(==(spec.names[i]), normalized)
        idx === nothing && throw(KeyError(spec.names[i]))
        indices[i] = idx
    end
    return Tuple(indices)
end

@generated function push_namedtuple_record_direct!(
    batch::B,
    record::NamedTuple{names},
    ::Val{field_indices},
) where {B, names, field_indices}
    expressions = Expr[]
    for i in eachindex(field_indices)
        push!(expressions, :(push!(batch[$i], getfield(record, $(field_indices[i])))))
    end
    return Expr(:block, expressions..., :(nothing))
end

@generated function push_namedtuple_record_direct_by_name!(
    batch::B,
    record::NamedTuple{names},
    ::Val{spec_names},
) where {B, names, spec_names}
    field_indices = Vector{Int}(undef, length(spec_names))
    for i in eachindex(spec_names)
        idx = findfirst(==(spec_names[i]), names)
        idx === nothing && return :(throw(KeyError($(QuoteNode(spec_names[i])))))
        field_indices[i] = idx
    end
    return :(push_namedtuple_record_direct!(batch, record, Val($(Tuple(field_indices)))))
end

@generated function push_namedtuple_record_fast_by_name!(
    batch::B,
    record::NamedTuple{names, T},
    ::Val{spec_names},
) where {B, names, T, spec_names}
    expressions = Expr[]
    for i in eachindex(spec_names)
        name = spec_names[i]
        idx = findfirst(==(name), names)
        idx === nothing && return :(throw(KeyError($(QuoteNode(name)))))

        value = :(getfield(record, $idx))
        dest_type = nonmissing_field_type(eltype(fieldtype(B, i)))
        field_type = nonmissing_field_type(fieldtype(T, idx))
        staged = if dest_type <: AbstractString && !(field_type <: AbstractString)
            :(record_string_value($value))
        elseif dest_type <: Date && !(field_type <: Date)
            :(record_date_value($value))
        elseif dest_type <: DateTime && !(field_type <: DateTime)
            :(record_datetime_value($value))
        else
            value
        end
        push!(expressions, :(push!(batch[$i], $staged)))
    end
    return Expr(:block, expressions..., :(nothing))
end

function push_namedtuple_record_fast_by_name!(
    batch,
    record,
    ::Val{spec_names},
) where {spec_names}
    throw(ArgumentError("Expected NamedTuple record, got $(typeof(record))"))
end

function push_record_maybe_fast!(
    batch_tuple,
    batch::Vector{AbstractVector},
    record,
    spec::InsertColumnsSpec,
    ::Val{expected_names},
    ::Val{field_indices},
    ::Val{direct_flags},
    ::Val{validate_records},
) where {expected_names, field_indices, direct_flags, validate_records}
    push_record!(batch, record, spec; validate = validate_records)
    return nothing
end

@generated function push_record_maybe_fast!(
    batch_tuple::B,
    batch::Vector{AbstractVector},
    record::NamedTuple{names},
    spec::InsertColumnsSpec,
    ::Val{expected_names},
    ::Val{field_indices},
    ::Val{direct_flags},
    ::Val{validate_records},
) where {B, names, expected_names, field_indices, direct_flags, validate_records}
    if names != expected_names
        return :(push_record!(batch, record, spec; validate = $validate_records))
    end

    length(field_indices) == length(direct_flags) ||
        throw(ArgumentError("field index and staging flag counts differ"))
    expressions = Expr[]
    for i in eachindex(field_indices)
        value = :(getfield(record, $(field_indices[i])))
        push_expr = direct_flags[i] ?
            :(push!(batch_tuple[$i], $value)) :
            :(push!(batch_tuple[$i], convert_insert_value($value, spec.asts[$i])))
        push!(expressions, push_expr)
    end
    return Expr(:block, expressions..., :(nothing))
end

function write_namedtuple_record_blocks!(
    sock::ClickHouseSock,
    records::AbstractVector,
    spec::InsertColumnsSpec,
    block_size::Integer;
    validate_records::Bool,
)::Bool
    isempty(records) && return true

    first_record = records[firstindex(records)]
    first_record isa NamedTuple || return false
    names = propertynames(first_record)

    field_indices = namedtuple_field_indices(names, spec; validate = validate_records)
    staging_actions = Tuple(record_staging_action(ast) for ast in spec.asts)
    direct_flags = Tuple(action == :direct for action in staging_actions)
    spec_names = Tuple(spec.names)
    all_fast = all(action != :convert for action in staging_actions) && !validate_records

    start = firstindex(records)
    last = lastindex(records)
    while start <= last
        stop = min(start + Int(block_size) - 1, last)
        rows_in_batch = stop - start + 1
        batch = sizehint_record_batch!(make_record_batch(spec), rows_in_batch)
        batch_tuple = Tuple(batch)
        for i in start:stop
            record = records[i]
            if all_fast && record isa NamedTuple
                push_namedtuple_record_fast_by_name!(batch_tuple, record, Val(spec_names))
            else
                push_record_maybe_fast!(
                    batch_tuple,
                    batch,
                    record,
                    spec,
                    Val(names),
                    Val(field_indices),
                    Val(direct_flags),
                    Val(validate_records),
                )
            end
        end
        write_record_batch!(sock, batch, spec; flush = false)
        start = stop + 1
    end
    return true
end

function normalize_all_missing_columns!(
    batch::Dict{Symbol, AbstractVector},
    valid_columns::Dict{Symbol, String},
)::Nothing
    for (name, data) in batch
        if eltype(data) == Missing
            type = parse_typestring(valid_columns[name])
            if type.name == :Nullable
                replacement = result_type(type)(undef, length(data))
                fill!(replacement, missing)
                batch[name] = replacement
            end
        end
    end
    return nothing
end

function normalize_all_missing_columns!(
    batch::Vector{AbstractVector},
    spec::InsertColumnsSpec,
)::Nothing
    for i in eachindex(batch)
        data = batch[i]
        if data !== nothing && eltype(data) == Missing
            type = parse_typestring(spec.types[i])
            if type.name == :Nullable
                replacement = result_type(type)(undef, length(data))
                fill!(replacement, missing)
                batch[i] = replacement
            end
        end
    end
    return nothing
end

function write_block_dict!(
    sock::ClickHouseSock,
    block_dict::AbstractDict{Symbol},
    valid_columns::Dict{Symbol, String},
    ;
    flush::Bool = true,
)::Nothing
    columns = dict2columns(block_dict, valid_columns)
    block = make_block(columns)
    write_packet(sock, block; flush = flush)
    return nothing
end

function write_block!(
    sock::ClickHouseSock,
    columns::Vector{Column},
    ;
    flush::Bool = true,
)::Nothing
    write_packet(sock, make_block(columns); flush = flush)
    return nothing
end

function write_block!(
    sock::ClickHouseSock,
    block,
    spec::InsertColumnsSpec,
    ;
    flush::Bool = true,
)::Nothing
    write_block!(sock, block_columns(block, spec); flush = flush)
    return nothing
end

function write_record_batch!(
    sock::ClickHouseSock,
    batch::Vector{AbstractVector},
    spec::InsertColumnsSpec,
    ;
    flush::Bool = true,
)::Nothing
    columns = Vector{Column}(undef, length(spec))
    for i in eachindex(spec.names)
        data = batch[i]
        columns[i] = Column(String(spec.names[i]), spec.types[i], data)
    end
    write_block!(sock, columns; flush = flush)
    return nothing
end

function make_block(
    columns::Vector{Column} = Column[];
    temp_table::AbstractString = "",
)::Block
    num_columns = length(columns)
    num_rows = num_columns == 0 ? 0 : length(columns[1].data)
    for col ∈ columns
        if length(col.data) != num_rows
            throw(DimensionMismatch(
                "Column $(col.name) has $(length(col.data)) rows, expected $(num_rows)"
            ))
        end
    end
    Block(String(temp_table), BlockInfo(), num_columns, num_rows, columns)
end

"""
    QueryStats()

Client-side aggregate of progress, profile, log, and profile-event packets seen
while a query is running. Progress counters are accumulated because ClickHouse
sends progress deltas.
"""
mutable struct QueryStats
    rows::UInt64
    bytes::UInt64
    total_rows::UInt64
    total_bytes::UInt64
    written_rows::UInt64
    written_bytes::UInt64
    elapsed_ns::UInt64
    profile_info::Union{Nothing, ServerProfileInfo}
    log_blocks::Vector{Block}
    profile_event_blocks::Vector{Block}
end

QueryStats() = QueryStats(0, 0, 0, 0, 0, 0, 0, nothing, Block[], Block[])

function record_progress!(stats::QueryStats, progress::ServerProgress)::Nothing
    stats.rows += UInt64(progress.rows)
    stats.bytes += UInt64(progress.bytes)
    stats.total_rows += UInt64(progress.total_rows)
    stats.total_bytes += UInt64(progress.total_bytes)
    stats.written_rows += UInt64(progress.written_rows)
    stats.written_bytes += UInt64(progress.written_bytes)
    stats.elapsed_ns = max(stats.elapsed_ns, UInt64(progress.elapsed_ns))
    return nothing
end

ensure_query_stats(stats::QueryStats) = stats
ensure_query_stats(::Nothing) = QueryStats()

"""
    QuerySchema

Ordered names and ClickHouse type strings for a result block or materialized
result. Duplicate names are preserved; name lookup returns the first match.
"""
struct QuerySchema
    names::Vector{Symbol}
    types::Vector{String}
    lookup::Dict{Symbol, Int}
end

function QuerySchema(columns::Vector{Column})
    names = Symbol[col.name |> Symbol for col in columns]
    types = String[col.type for col in columns]
    lookup = Dict{Symbol, Int}()
    for (i, name) in pairs(names)
        haskey(lookup, name) || (lookup[name] = i)
    end
    return QuerySchema(names, types, lookup)
end

Base.length(schema::QuerySchema) = length(schema.names)

abstract type AbstractQueryColumns end

"""
    QueryBlock

One non-empty ClickHouse result block with ordered column access. Supports
`block[:name]`, integer column access, and the Tables.jl column interface.
"""
struct QueryBlock <: AbstractQueryColumns
    schema::QuerySchema
    columns::Vector{Column}
end

QueryBlock(block::Block) = QueryBlock(QuerySchema(block.columns), block.columns)

"""
    QueryResult

Materialized query result with ordered columns, ClickHouse schema metadata, and
the accumulated `QueryStats`. `totals` and `extremes` hold ClickHouse totals
or extremes blocks when the server sends them; ordinary rows are never mixed
with those blocks. Supports `result[:name]`, integer column access, and the
Tables.jl column interface.
"""
struct QueryResult <: AbstractQueryColumns
    schema::QuerySchema
    columns::Vector{Column}
    stats::QueryStats
    totals::Union{Nothing, QueryBlock}
    extremes::Union{Nothing, QueryBlock}
end

QueryResult(schema::QuerySchema, columns::Vector{Column}, stats::QueryStats) =
    QueryResult(schema, columns, stats, nothing, nothing)

Base.haskey(x::AbstractQueryColumns, name::Symbol) = haskey(x.schema.lookup, name)
Base.haskey(x::AbstractQueryColumns, name::AbstractString) = haskey(x, Symbol(name))
Base.keys(x::AbstractQueryColumns) = x.schema.names
Base.values(x::AbstractQueryColumns) = (column.data for column in x.columns)
Base.pairs(x::AbstractQueryColumns) =
    (x.schema.names[i] => x.columns[i].data for i in eachindex(x.columns))
Base.get(x::AbstractQueryColumns, name::Symbol, default) =
    haskey(x, name) ? x[name] : default
Base.get(x::AbstractQueryColumns, name::AbstractString, default) =
    get(x, Symbol(name), default)

Base.getindex(x::AbstractQueryColumns, i::Integer) = x.columns[i].data
Base.getindex(x::AbstractQueryColumns, name::Symbol) =
    x.columns[x.schema.lookup[name]].data
Base.getindex(x::AbstractQueryColumns, name::AbstractString) = x[Symbol(name)]

columnnames(x::AbstractQueryColumns) = copy(x.schema.names)
columntypes(x::AbstractQueryColumns) = copy(x.schema.types)
nrows(x::AbstractQueryColumns) = isempty(x.columns) ? 0 : length(x.columns[1].data)

Tables.istable(::Type{<:AbstractQueryColumns}) = true
Tables.columnaccess(::Type{<:AbstractQueryColumns}) = true
Tables.columns(x::AbstractQueryColumns) = x
Tables.columnnames(x::AbstractQueryColumns) = Tuple(x.schema.names)
Tables.getcolumn(x::AbstractQueryColumns, i::Int) = x[i]
Tables.getcolumn(x::AbstractQueryColumns, name::Symbol) = x[name]
Tables.getcolumn(x::AbstractQueryColumns, ::Type{T}, i::Int, name::Symbol) where {T} =
    Tables.getcolumn(x, i)
Tables.schema(x::AbstractQueryColumns) =
    Tables.Schema(Tuple(x.schema.names), Tuple(eltype(column.data) for column in x.columns))

copy_column(column::Column) = Column(column.name, column.type, copy(column.data))

function append_block_columns!(dest::Vector{Column}, block::QueryBlock)::Nothing
    length(dest) == length(block.columns) ||
        throw(DimensionMismatch("result block has $(length(block.columns)) columns, expected $(length(dest))"))
    for i in eachindex(dest)
        dest[i].name == block.columns[i].name && dest[i].type == block.columns[i].type ||
            throw(ArgumentError("result block schema changed at column $(i)"))
        append!(dest[i].data, block.columns[i].data)
    end
    return nothing
end

function result_dict(result::QueryResult)::Dict{Symbol, AbstractVector}
    dict = Dict{Symbol, AbstractVector}()
    for (name, data) in pairs(result)
        dict[name] = data
    end
    return dict
end

function handle_query_event(
    sock::ClickHouseSock,
    packet;
    stats::Union{Nothing, QueryStats} = nothing,
    progress_callback::Union{Nothing, Function} = nothing,
    log_callback::Union{Nothing, Function} = nothing,
    profile_events_callback::Union{Nothing, Function} = nothing,
)::Bool
    if packet isa ServerProgress
        stats !== nothing && record_progress!(stats, packet)
        progress_callback !== nothing && progress_callback(packet)
        return true
    elseif packet isa ServerProfileInfo
        stats !== nothing && (stats.profile_info = packet)
        return true
    elseif packet isa ServerLog
        stats !== nothing && push!(stats.log_blocks, packet.data)
        log_callback !== nothing && log_callback(packet.data)
        return true
    elseif packet isa ServerProfileEvents
        stats !== nothing && push!(stats.profile_event_blocks, packet.data)
        profile_events_callback !== nothing && profile_events_callback(packet.data)
        return true
    elseif packet isa ServerPartUUIDs
        return true
    elseif packet isa ServerTimezoneUpdate
        sock.server_timezone = packet.timezone
        return true
    elseif packet isa ServerReadTaskRequest
        throw(UnsupportedProtocolFeature(
            "server read-task requests are not supported by this client",
        ))
    end
    return false
end

function read_insert_sample_block(
    sock::ClickHouseSock;
    stats::Union{Nothing, QueryStats} = nothing,
    progress_callback::Union{Nothing, Function} = nothing,
    log_callback::Union{Nothing, Function} = nothing,
    profile_events_callback::Union{Nothing, Function} = nothing,
)::Block
    while true
        packet = read_server_packet(sock)
        if packet isa ServerTableColumns
            return packet.sample_block
        elseif packet isa ServerData
            return packet.data
        elseif handle_query_event(
            sock,
            packet;
            stats = stats,
            progress_callback = progress_callback,
            log_callback = log_callback,
            profile_events_callback = profile_events_callback,
        )
            continue
        else
            error("Unexpected packet received while reading insert sample block: $(packet)")
        end
    end
end

function drain_query_response(
    sock::ClickHouseSock;
    stats::Union{Nothing, QueryStats} = nothing,
    progress_callback::Union{Nothing, Function} = nothing,
    log_callback::Union{Nothing, Function} = nothing,
    profile_events_callback::Union{Nothing, Function} = nothing,
)::Nothing
    while true
        packet = read_server_packet(sock)
        if handle_query_event(
            sock,
            packet;
            stats = stats,
            progress_callback = progress_callback,
            log_callback = log_callback,
            profile_events_callback = profile_events_callback,
        )
            continue
        elseif packet isa ServerEndOfStream
            return nothing
        else
            error("Unexpected packet received while waiting for query completion: $(packet)")
        end
    end
end

function read_select_sample_block(
    sock::ClickHouseSock;
    stats::Union{Nothing, QueryStats} = nothing,
    progress_callback::Union{Nothing, Function} = nothing,
    log_callback::Union{Nothing, Function} = nothing,
    profile_events_callback::Union{Nothing, Function} = nothing,
)::Block
    while true
        packet = read_server_packet(sock)
        if packet isa ServerData
            return packet.data
        elseif handle_query_event(
            sock,
            packet;
            stats = stats,
            progress_callback = progress_callback,
            log_callback = log_callback,
            profile_events_callback = profile_events_callback,
        )
            continue
        else
            error("Unexpected packet received while reading query sample block: $(packet)")
        end
    end
end


"Send a ping request and wait for the response."
function ping(sock::ClickHouseSock)::Nothing
    @using_socket sock begin
        write_packet(sock, ClientPing())
        read_server_packet(sock)::ServerPong
    end
    nothing
end

"Send a cancellation packet for the currently running query."
function cancel(sock::ClickHouseSock)::Nothing
    @guarded sock begin
        (!is_connected(sock)) && error("ClickHouseSock not connected")
        write_packet(sock, ClientCancel())
    end
    return nothing
end

table_ref(sock::ClickHouseSock, table::TableRef) = table
table_ref(sock::ClickHouseSock, table::AbstractString) =
    TableRef(sock.settings.database, table)

"""
    table_status(sock, table_or_tables)

Request ClickHouse table status information over the native protocol. A string
table name uses the socket's default database; pass `TableRef(database, table)`
for an explicit database. The return value is a dictionary keyed by `TableRef`.
"""
function table_status(sock::ClickHouseSock, table::Union{TableRef, AbstractString})
    return table_status(sock, [table])
end

function table_status(sock::ClickHouseSock, tables)
    @using_socket sock begin
        has_tables_status(sock.server_rev) || throw(UnsupportedProtocolFeature(
            "table status requests require protocol revision $(has_tables_status_rev())",
        ))
        refs = TableRef[table_ref(sock, table) for table in tables]
        write_packet(sock, ClientTableStatusRequest(refs))
        response = read_server_packet(sock)::ServerTablesStatusResponse
        response.table_states_by_id
    end
end

"Execute a DDL query."
function execute(
    sock::ClickHouseSock,
    ddl_query::AbstractString;
    options::QueryOptions = QueryOptions(),
    stats::Union{Nothing, QueryStats} = nothing,
    progress_callback::Union{Nothing, Function} = nothing,
    log_callback::Union{Nothing, Function} = nothing,
    profile_events_callback::Union{Nothing, Function} = nothing,
)::Nothing
    query_stats = stats
    @using_socket sock begin
        try
            write_query(sock, ddl_query; options = options)
            drain_query_response(
                sock;
                stats = query_stats,
                progress_callback = progress_callback,
                log_callback = log_callback,
                profile_events_callback = profile_events_callback,
            )
        finally
            finish_query!(sock)
        end
    end
    nothing
end

"""
Insert columnar blocks into a table, reading from an iterable.

`table` is treated as an identifier (`"table"`, `"database.table"`, or
`TableRef`) and quoted before sending SQL. The iterable should yield blocks
whose keys are column names and whose values are column vectors.
"""
function insert(
    sock::ClickHouseSock,
    table::Union{TableRef, AbstractString},
    iter;
    options::QueryOptions = QueryOptions(),
    stats::Union{Nothing, QueryStats} = nothing,
    progress_callback::Union{Nothing, Function} = nothing,
    log_callback::Union{Nothing, Function} = nothing,
    profile_events_callback::Union{Nothing, Function} = nothing,
)::Nothing
    query_stats = stats
    @using_socket sock begin
        try
            write_query(sock, "INSERT INTO $(table_identifier(table)) VALUES"; options = options)
            sample_block = read_insert_sample_block(
                sock;
                stats = query_stats,
                progress_callback = progress_callback,
                log_callback = log_callback,
                profile_events_callback = profile_events_callback,
            )

            spec = InsertColumnsSpec(sample_block.columns)

            for block_dict ∈ iter
                write_block!(sock, block_dict, spec; flush = false)
            end

            # Empty block = end of data.
            write_packet(sock, make_block())

            drain_query_response(
                sock;
                stats = query_stats,
                progress_callback = progress_callback,
                log_callback = log_callback,
                profile_events_callback = profile_events_callback,
            )
        finally
            finish_query!(sock)
        end
    end
    nothing
end

"""
Insert row records into a table, reading from an iterable of dictionaries.

Each record is a dictionary whose keys are column names (`Symbol` or string) and
whose values are scalar row values. Records are batched into columnar ClickHouse
blocks and then written using the native insert protocol.

`table` is treated as an identifier (`"table"`, `"database.table"`, or
`TableRef`) and quoted before sending SQL.

By default `insert_records` reads only the columns required by the target table.
Pass `validate_records=true` to perform full per-row column-set validation and
reject missing or extra record keys before encoding.
"""
function insert_records(
    sock::ClickHouseSock,
    table::Union{TableRef, AbstractString},
    records;
    block_size::Integer = sock.settings.max_insert_block_size,
    options::QueryOptions = QueryOptions(),
    stats::Union{Nothing, QueryStats} = nothing,
    progress_callback::Union{Nothing, Function} = nothing,
    log_callback::Union{Nothing, Function} = nothing,
    profile_events_callback::Union{Nothing, Function} = nothing,
    validate_records::Bool = false,
)::Nothing
    block_size > 0 ||
        throw(ArgumentError("block_size must be positive"))

    query_stats = stats
    @using_socket sock begin
        try
            write_query(sock, "INSERT INTO $(table_identifier(table)) VALUES"; options = options)
            sample_block = read_insert_sample_block(
                sock;
                stats = query_stats,
                progress_callback = progress_callback,
                log_callback = log_callback,
                profile_events_callback = profile_events_callback,
            )

            spec = InsertColumnsSpec(sample_block.columns)
            if records isa AbstractVector &&
                    write_namedtuple_record_blocks!(
                        sock,
                        records,
                        spec,
                        block_size;
                        validate_records = validate_records,
                    )
                # Empty block = end of data.
                write_packet(sock, make_block())

                drain_query_response(
                    sock;
                    stats = query_stats,
                    progress_callback = progress_callback,
                    log_callback = log_callback,
                    profile_events_callback = profile_events_callback,
                )
                return nothing
            end

            batch = make_record_batch(spec)
            records isa AbstractVector &&
                sizehint_record_batch!(batch, min(Int(block_size), length(records)))
            rows_in_batch = 0

            for record ∈ records
                push_record!(
                    batch,
                    record,
                    spec;
                    validate = validate_records,
                )
                rows_in_batch += 1

                if rows_in_batch >= block_size
                    write_record_batch!(sock, batch, spec; flush = false)
                    reset_record_batch!(batch)
                    rows_in_batch = 0
                end
            end

            if rows_in_batch > 0
                write_record_batch!(sock, batch, spec; flush = false)
            end

            # Empty block = end of data.
            write_packet(sock, make_block())

            drain_query_response(
                sock;
                stats = query_stats,
                progress_callback = progress_callback,
                log_callback = log_callback,
                profile_events_callback = profile_events_callback,
            )
        finally
            finish_query!(sock)
        end
    end
    nothing
end

struct TableColumnBlock
    names::Vector{Symbol}
    columns::Vector{AbstractVector}
    lookup::Dict{Symbol, Int}
end

function record_column_names(block::TableColumnBlock)::Vector{Symbol}
    return copy(block.names)
end

function block_column(block::TableColumnBlock, name::Symbol)::AbstractVector
    idx = get(block.lookup, name, nothing)
    idx === nothing && throw(KeyError(name))
    return block.columns[idx]
end

Base.keys(block::TableColumnBlock) = block.names
Base.getindex(block::TableColumnBlock, name::Symbol) = block_column(block, name)
Base.getindex(block::TableColumnBlock, name::AbstractString) = block[Symbol(name)]
Base.pairs(block::TableColumnBlock) =
    (block.names[i] => block.columns[i] for i in eachindex(block.names))

struct TableBlockIterator
    names::Vector{Symbol}
    columns::Vector{AbstractVector}
    lookup::Dict{Symbol, Int}
    block_size::Int
    nrows::Int
end

Base.IteratorSize(::Type{TableBlockIterator}) = Base.HasLength()
Base.IteratorEltype(::Type{TableBlockIterator}) = Base.HasEltype()
Base.eltype(::Type{TableBlockIterator}) = TableColumnBlock
Base.length(iter::TableBlockIterator) = cld(iter.nrows, iter.block_size)

function column_slice(column::AbstractVector, range::UnitRange{Int})
    if first(range) == firstindex(column) && last(range) == lastindex(column)
        return column
    end
    try
        return view(column, range)
    catch
        return column[range]
    end
end

function Base.iterate(iter::TableBlockIterator, start::Int = 1)
    start > iter.nrows && return nothing
    stop = min(start + iter.block_size - 1, iter.nrows)
    range = start:stop
    columns = Vector{AbstractVector}(undef, length(iter.names))
    for i in eachindex(iter.names)
        columns[i] = column_slice(iter.columns[i], range)
    end
    block = TableColumnBlock(iter.names, columns, iter.lookup)
    return (block, stop + 1)
end

function table_block_iterator(source, block_size::Integer)::TableBlockIterator
    block_size > 0 || throw(ArgumentError("block_size must be positive"))
    Tables.istable(typeof(source)) ||
        throw(ArgumentError("insert_table source must implement the Tables.jl interface"))
    Tables.columnaccess(typeof(source)) ||
        throw(ArgumentError("table_block_iterator requires a column-access Tables.jl source"))

    table = Tables.columns(source)
    source_names = collect(Tables.columnnames(table))
    names = Symbol[Symbol(name) for name in source_names]
    lookup = Dict{Symbol, Int}()
    for (i, name) in pairs(names)
        haskey(lookup, name) &&
            throw(ArgumentError("Duplicate Tables.jl column name after Symbol conversion: $(name)"))
        lookup[name] = i
    end
    columns = AbstractVector[]
    nrows = nothing
    for name in source_names
        column = Tables.getcolumn(table, name)
        vector = column isa AbstractVector ? column : collect(column)
        if nrows === nothing
            nrows = length(vector)
        elseif length(vector) != nrows
            throw(DimensionMismatch("Tables.jl source columns have different lengths"))
        end
        push!(columns, vector)
    end
    nrows = something(nrows, 0)
    return TableBlockIterator(names, columns, lookup, Int(block_size), Int(nrows))
end

"""
    insert_table(sock, table, source; block_size, options, ...)

Insert any Tables.jl-compatible column table, including `DataFrame` and
`Arrow.Table`, through the native columnar insert protocol. `table` is treated
as an identifier (`"table"`, `"database.table"`, or `TableRef`) and quoted
before sending SQL.
"""
function insert_table(
    sock::ClickHouseSock,
    table::Union{TableRef, AbstractString},
    source;
    block_size::Integer = sock.settings.max_insert_block_size,
    options::QueryOptions = QueryOptions(),
    stats::Union{Nothing, QueryStats} = nothing,
    progress_callback::Union{Nothing, Function} = nothing,
    log_callback::Union{Nothing, Function} = nothing,
    profile_events_callback::Union{Nothing, Function} = nothing,
    validate_records::Bool = false,
)::Nothing
    Tables.istable(typeof(source)) ||
        throw(ArgumentError("insert_table source must implement the Tables.jl interface"))

    if Tables.columnaccess(typeof(source))
        blocks = table_block_iterator(source, block_size)
        return insert(
            sock,
            table,
            blocks;
            options = options,
            stats = stats,
            progress_callback = progress_callback,
            log_callback = log_callback,
            profile_events_callback = profile_events_callback,
        )
    end

    return insert_records(
        sock,
        table,
        Tables.rows(source);
        block_size = block_size,
        options = options,
        stats = stats,
        progress_callback = progress_callback,
        log_callback = log_callback,
        profile_events_callback = profile_events_callback,
        validate_records = validate_records,
    )
end

"""
    select_callback(callback, sock, query; totals_callback, extremes_callback, ...)

Execute a query, invoking `callback` for each non-empty data block.
`totals_callback` and `extremes_callback` receive `QueryBlock` values for
ClickHouse totals and extremes packets when supplied.
"""
function select_callback(
    callback::Function,
    sock::ClickHouseSock,
    query::AbstractString;
    options::QueryOptions = QueryOptions(),
    stats::Union{Nothing, QueryStats} = nothing,
    sample_callback::Union{Nothing, Function} = nothing,
    totals_callback::Union{Nothing, Function} = nothing,
    extremes_callback::Union{Nothing, Function} = nothing,
    progress_callback::Union{Nothing, Function} = nothing,
    log_callback::Union{Nothing, Function} = nothing,
    profile_events_callback::Union{Nothing, Function} = nothing,
)::Nothing
    query_stats = stats
    @using_socket sock begin
        try
            write_query(sock, query; options = options)

            sample_block = read_select_sample_block(
                sock;
                stats = query_stats,
                progress_callback = progress_callback,
                log_callback = log_callback,
                profile_events_callback = profile_events_callback,
            )
            if UInt64(sample_block.num_rows) != 0
                error("Expected empty sample block, got $(sample_block.num_rows) rows")
            end
            sample_callback !== nothing && sample_callback(QueryBlock(sample_block))

            while true
                packet = read_server_packet(sock)
                if packet isa ServerEndOfStream
                    break
                elseif packet isa ServerData
                    if UInt64(packet.data.num_rows) != 0
                        callback(QueryBlock(packet.data))
                    end
                elseif packet isa ServerTotals
                    totals_callback !== nothing && totals_callback(QueryBlock(packet.data))
                elseif packet isa ServerExtremes
                    extremes_callback !== nothing && extremes_callback(QueryBlock(packet.data))
                elseif handle_query_event(
                        sock,
                        packet;
                        stats = query_stats,
                        progress_callback = progress_callback,
                        log_callback = log_callback,
                        profile_events_callback = profile_events_callback,
                    )
                    continue
                else
                    error("Unexpected packet received while reading query result: $(packet)")
                end
            end
        finally
            finish_query!(sock)
        end
    end
end

struct SelectChannelClosed <: Exception end

channel_closed_exception(e) =
    e isa InvalidStateException && e.state == :closed

function put_select_channel!(sock::ClickHouseSock, ch::Channel{QueryBlock}, block::QueryBlock)
    try
        put!(ch, block)
    catch e
        if channel_closed_exception(e)
            try
                cancel(sock)
            catch
                # The query task may already be unwinding or the connection may
                # already be closed. In both cases the producer should exit.
            end
            throw(SelectChannelClosed())
        end
        rethrow()
    end
    return nothing
end

"Execute a query, streaming the resulting blocks through a channel."
function select_channel(
    sock::ClickHouseSock,
    query::AbstractString;
    csize = 0,
    kwargs...,
)::Channel{QueryBlock}
    ch = Channel{QueryBlock}(csize)
    task = @async begin
        try
            select_callback(sock, query; kwargs...) do block
                put_select_channel!(sock, ch, block)
            end
            isopen(ch) && close(ch)
        catch e
            if e isa SelectChannelClosed
                isopen(ch) && close(ch)
            else
                isopen(ch) && close(ch, e)
                rethrow()
            end
        end
    end
    bind(ch, task)
    return ch
end

"""
    select(sock, sql; kwargs...) -> QueryResult

Execute a query, flattening data blocks into an ordered `QueryResult`. Totals
and extremes packets are exposed as `result.totals` and `result.extremes`
instead of being appended to ordinary rows.
"""
function select(
    sock::ClickHouseSock,
    sql::AbstractString;
    stats::Union{Nothing, QueryStats} = nothing,
    kwargs...
)::QueryResult
    query_stats = ensure_query_stats(stats)
    result_columns = Column[]
    result_schema = Ref{Union{Nothing, QuerySchema}}(nothing)
    result_totals = Ref{Union{Nothing, QueryBlock}}(nothing)
    result_extremes = Ref{Union{Nothing, QueryBlock}}(nothing)

    function remember_sample(block::QueryBlock)
        result_schema[] = block.schema
        empty!(result_columns)
        append!(result_columns, copy_column.(block.columns))
        return nothing
    end

    select_callback(
        sock,
        sql;
        stats = query_stats,
        sample_callback = remember_sample,
        totals_callback = block -> (result_totals[] = block),
        extremes_callback = block -> (result_extremes[] = block),
        kwargs...,
    ) do block
        append_block_columns!(result_columns, block)
    end

    schema = result_schema[] === nothing ? QuerySchema(result_columns) : result_schema[]
    return QueryResult(
        schema,
        result_columns,
        query_stats,
        result_totals[],
        result_extremes[],
    )
end

"""
    query(sock, sql; kwargs...) -> QueryResult

Execute a query, flattening data blocks into an ordered `QueryResult`. This is
the exported materialized query API. `ClickHouseClient.select` remains
available as a qualified alias for users who prefer SQL terminology.
"""
query(sock::ClickHouseSock, sql::AbstractString; kwargs...) =
    select(sock, sql; kwargs...)

"Execute a query, flattening blocks into a DataFrame. Requires DataFrames.jl."
function select_df(args...; kwargs...)
    throw(ArgumentError(
        "select_df requires DataFrames.jl. Load DataFrames first with `using DataFrames`.",
    ))
end

# ============================================================================ #

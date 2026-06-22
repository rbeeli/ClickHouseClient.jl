typename_parse_error(s) = error("typename parse error in $(s)")

is_type_quote(c::Char) = c == '\'' || c == '"' || c == '`'

function first_unquoted_lparen(s::AbstractString)
    quote_char = nothing
    escaped = false
    for i in eachindex(s)
        c = s[i]
        if escaped
            escaped = false
        elseif quote_char !== nothing
            if c == '\\'
                escaped = true
            elseif c == quote_char
                quote_char = nothing
            end
        elseif is_type_quote(c)
            quote_char = c
        elseif c == '('
            return i
        elseif c == ')'
            typename_parse_error(s)
        end
    end
    quote_char === nothing || typename_parse_error(s)
    return nothing
end

function split_type_arguments(inner::AbstractString, original::AbstractString)
    args = String[]
    isempty(inner) && return args

    start = firstindex(inner)
    depth = 0
    quote_char = nothing
    escaped = false

    for i in eachindex(inner)
        c = inner[i]
        if escaped
            escaped = false
        elseif quote_char !== nothing
            if c == '\\'
                escaped = true
            elseif c == quote_char
                quote_char = nothing
            end
        elseif is_type_quote(c)
            quote_char = c
        elseif c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
            depth >= 0 || typename_parse_error(original)
        elseif c == ',' && depth == 0
            part = strip(String(inner[start:prevind(inner, i)]))
            isempty(part) && typename_parse_error(original)
            push!(args, part)
            start = nextind(inner, i)
        end
    end

    quote_char === nothing || typename_parse_error(original)
    depth == 0 || typename_parse_error(original)
    start <= lastindex(inner) || typename_parse_error(original)

    part = strip(String(inner[start:lastindex(inner)]))
    isempty(part) && typename_parse_error(original)
    push!(args, part)
    return args
end

function type_after_tuple_field_name(arg::AbstractString, original::AbstractString)
    text = strip(String(arg))
    isempty(text) && typename_parse_error(original)

    i = firstindex(text)
    if is_type_quote(text[i])
        quote_char = text[i]
        escaped = false
        i = nextind(text, i)
        while i <= lastindex(text)
            c = text[i]
            if escaped
                escaped = false
            elseif c == '\\'
                escaped = true
            elseif c == quote_char
                i = nextind(text, i)
                break
            end
            i = nextind(text, i)
        end
        i <= lastindex(text) || typename_parse_error(original)
    else
        while i <= lastindex(text) && !isspace(text[i])
            i = nextind(text, i)
        end
    end

    i <= lastindex(text) || typename_parse_error(original)
    rest = strip(String(text[i:lastindex(text)]))
    isempty(rest) && typename_parse_error(original)
    return rest
end

function parse_tuple_argument(arg::AbstractString, original::AbstractString)
    try
        parsed = _parse_typestring(arg)
        parsed isa TypeAst && return parsed
    catch
        # It may still be a named tuple field, e.g. `x Array(UInt8)`.
    end
    return parse_typestring(type_after_tuple_field_name(arg, original))
end

function _parse_typestring(s::AbstractString)
    s = strip(String(s))
    (isempty(s) || first(s) == '(') && typename_parse_error(s)

    open_pos = first_unquoted_lparen(s)
    if isnothing(open_pos)
        type_name = Symbol(s)
        return is_ch_type(type_name) ? TypeAst(type_name) : s
    end

    last(s) == ')' || typename_parse_error(s)
    type_name_text = strip(String(s[firstindex(s):prevind(s, open_pos)]))
    isempty(type_name_text) && typename_parse_error(s)
    type_name = Symbol(type_name_text)
    is_ch_type(type_name) || typename_parse_error(s)

    ast = TypeAst(type_name)
    inner = String(s[nextind(s, open_pos):prevind(s, lastindex(s))])
    for arg in split_type_arguments(inner, s)
        parsed = type_name == :Tuple ?
            parse_tuple_argument(arg, s) :
            _parse_typestring(arg)
        push!(ast, parsed)
    end
    return ast
end

function type_arg_error(original::AbstractString, message::AbstractString)
    error("typename parse error in $(original): $(message)")
end

function require_arity(ast::TypeAst, original::AbstractString, valid)::Nothing
    length(ast.args) in valid ||
        type_arg_error(original, "$(ast.name) expects $(valid) arguments, got $(length(ast.args))")
    return nothing
end

function require_type_args(ast::TypeAst, original::AbstractString, indices)::Nothing
    for i in indices
        ast.args[i] isa TypeAst ||
            type_arg_error(original, "$(ast.name) argument $(i) must be a ClickHouse type")
    end
    return nothing
end

function require_string_args(ast::TypeAst, original::AbstractString, indices)::Nothing
    for i in indices
        ast.args[i] isa String ||
            type_arg_error(original, "$(ast.name) argument $(i) must be a parameter")
    end
    return nothing
end

function validate_type_ast!(ast::TypeAst, original::AbstractString)::Nothing
    for arg in ast.args
        arg isa TypeAst && validate_type_ast!(arg, original)
    end

    name = ast.name
    if name in (
        :UInt8, :UInt16, :UInt32, :UInt64, :UInt128, :UInt256,
        :Int8, :Int16, :Int32, :Int64, :Int128, :Int256,
        :BFloat16, :Float32, :Float64, :String, :Bool, :Date, :Date32,
        :Time, :UUID, :IPv4, :IPv6, :Nothing,
    )
        require_arity(ast, original, 0:0)
    elseif name == :Dynamic || name == :JSON
        isempty(ast.args) ||
            type_arg_error(original, "$(name) parameters are not supported")
    elseif name == :FixedString ||
            name == :Decimal32 || name == :Decimal64 ||
            name == :Decimal128 || name == :Decimal256 ||
            name == :Time64
        require_arity(ast, original, 1:1)
        require_string_args(ast, original, 1:1)
    elseif name == :Decimal
        require_arity(ast, original, 1:2)
        require_string_args(ast, original, 1:length(ast.args))
    elseif name == :DateTime
        require_arity(ast, original, 0:1)
        require_string_args(ast, original, 1:length(ast.args))
    elseif name == :DateTime64
        require_arity(ast, original, 1:2)
        require_string_args(ast, original, 1:length(ast.args))
    elseif name == :Array || name == :Nullable || name == :LowCardinality
        require_arity(ast, original, 1:1)
        require_type_args(ast, original, 1:1)
    elseif name == :Map || name == :SimpleAggregateFunction
        require_arity(ast, original, 2:2)
        name == :Map && require_type_args(ast, original, 1:2)
        name == :SimpleAggregateFunction && begin
            require_string_args(ast, original, 1:1)
            require_type_args(ast, original, 2:2)
        end
    elseif name == :Tuple || name == :Variant
        require_arity(ast, original, 1:typemax(Int))
        require_type_args(ast, original, 1:length(ast.args))
    elseif name == :Enum8 || name == :Enum16
        require_arity(ast, original, 1:typemax(Int))
        require_string_args(ast, original, 1:length(ast.args))
    end
    return nothing
end

function parse_typestring(s::AbstractString)
    result = _parse_typestring(s)
    result isa TypeAst || typename_parse_error(s)
    validate_type_ast!(result, String(s))
    return result
end

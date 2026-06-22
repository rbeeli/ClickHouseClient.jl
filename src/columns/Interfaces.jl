is_ch_type(::Val{N})  where {N} = false
is_ch_type(str::String)  = is_ch_type(Val(Symbol(str)))
is_ch_type(s::Symbol)  = is_ch_type(Val(s))

can_be_nullable(::Val{N}) where {N} = true
can_be_nullable(s::Symbol) = can_be_nullable(Val(s))

result_type(::Val{N}, args...)  where {N} =
    error("Unsupported type ", N, " with arguments: ", args...)

result_type(ast::TypeAst) =
                result_type(Val(ast.name), ast.args...)

#prefixes writes/reades before any column data.
#For now prefix exists only for LowCardinality columns
write_state_prefix(sock::ClickHouseSock, ::Val{N}, args...) where {N} = nothing
read_state_prefix(sock::ClickHouseSock, ::Val{N}, args...) where {N} = nothing

write_state_prefix(sock::ClickHouseSock, ast::TypeAst) =
                write_state_prefix_maybe_ast(sock, Val(ast.name), ast, ast.args...)

write_state_prefix_maybe_ast(sock::ClickHouseSock, ::Val{N}, ast::TypeAst, args...) where {N} =
                write_state_prefix(sock, Val(N), args...)

write_state_prefix_maybe_ast(
    sock::ClickHouseSock,
    ::Val{:Dynamic},
    ast::TypeAst,
    args...,
) = write_state_prefix(sock, Val(:Dynamic), ast, args...)

function read_state_prefix(sock::ClickHouseSock, ast::TypeAst)
    ast.state = read_state_prefix(sock, Val(ast.name), ast.args...)
    return ast.state
end

function read_col_data(sock::ClickHouseSock,
                        num_rows::VarUInt, ::Val{N}, args...) where {N}
    throw(
        ArgumentError(
            string("Unsupported type ", N, " with arguments: ", args...)
            )
        )
end

function write_col_data(sock::ClickHouseSock,
                        data::T, ::Val{N}, args...) where {T, N}
    throw(
        ArgumentError(
            string(
                "Unsupported write jl type $T into ch type ",
                N,
                " with arguments: ",
                args...
            )
            )
        )
end

read_col_data(sock::ClickHouseSock, num_rows::VarUInt, ast::TypeAst) =
                read_col_data_maybe_ast(sock, num_rows, Val(ast.name), ast, ast.args...)

read_col_data_maybe_ast(
    sock::ClickHouseSock,
    num_rows::VarUInt,
    ::Val{N},
    ast::TypeAst,
    args...,
) where {N} = read_col_data(sock, num_rows, Val(N), args...)

read_col_data_maybe_ast(
    sock::ClickHouseSock,
    num_rows::VarUInt,
    ::Val{:Variant},
    ast::TypeAst,
    args...,
) = read_col_data(sock, num_rows, Val(:Variant), ast, args...)

read_col_data_maybe_ast(
    sock::ClickHouseSock,
    num_rows::VarUInt,
    ::Val{:Dynamic},
    ast::TypeAst,
    args...,
) = read_col_data(sock, num_rows, Val(:Dynamic), ast, args...)

read_col_data_maybe_ast(
    sock::ClickHouseSock,
    num_rows::VarUInt,
    ::Val{:JSON},
    ast::TypeAst,
    args...,
) = read_col_data(sock, num_rows, Val(:JSON), ast, args...)

write_col_data(sock::ClickHouseSock, data, ast::TypeAst) =
                write_col_data_maybe_ast(sock, data, Val(ast.name), ast, ast.args...)

write_col_data_maybe_ast(
    sock::ClickHouseSock,
    data,
    ::Val{N},
    ast::TypeAst,
    args...,
) where {N} = write_col_data(sock, data, Val(N), args...)

write_col_data_maybe_ast(
    sock::ClickHouseSock,
    data,
    ::Val{:Variant},
    ast::TypeAst,
    args...,
) = write_col_data(sock, data, Val(:Variant), ast, args...)

write_col_data_maybe_ast(
    sock::ClickHouseSock,
    data,
    ::Val{:Dynamic},
    ast::TypeAst,
    args...,
) = write_col_data(sock, data, Val(:Dynamic), ast, args...)

write_col_data_maybe_ast(
    sock::ClickHouseSock,
    data,
    ::Val{:JSON},
    ast::TypeAst,
    args...,
) = write_col_data(sock, data, Val(:JSON), ast, args...)

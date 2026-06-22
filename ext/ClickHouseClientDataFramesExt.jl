module ClickHouseClientDataFramesExt

import ClickHouseClient: ClickHouseSock, query, select_df
import DataFrames: DataFrame

function select_df(
    sock::ClickHouseSock,
    sql::AbstractString;
    kwargs...,
)::DataFrame
    return DataFrame(query(sock, sql; kwargs...); copycols = false)
end

end

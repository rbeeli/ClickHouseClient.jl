
macro server_capability(name::Symbol, revision::Int)

    has_func = :(@inline $name(rev) = rev >= $revision)
    rev_func_name = Symbol(name, "_rev")
    rev_func = :(@inline $rev_func_name() = $revision)
    return  quote
                $(esc(has_func))
                $(esc(rev_func))
            end


end

@server_capability has_temporary_tables 50264
@server_capability has_total_rows_in_progress 51554
@server_capability has_block_info 51903
@server_capability has_client_info 54032
@server_capability has_server_timezone 54058
@server_capability has_quota_key 54060
@server_capability has_tables_status 54226
@server_capability has_server_display_name 54372
@server_capability has_version_patch 54401
@server_capability has_server_logs 54406
@server_capability has_column_dafaults_metadata 54410
@server_capability has_client_write_info 54420
@server_capability has_settings_serialized_as_strings 54429
@server_capability has_scalars 54429
@server_capability has_interserver_secret 54441
@server_capability has_opentelemetry 54442
@server_capability has_distributed_depth 54448
@server_capability has_initial_query_start_time 54449
@server_capability has_parallel_replicas 54453
@server_capability has_custom_serialization 54454
@server_capability has_addendum 54458
@server_capability has_addendum_quota_key 54458
@server_capability has_parameters 54459
@server_capability has_server_query_time_in_progress 54460
@server_capability has_password_complexity_rules 54461
@server_capability has_interserver_secret_v2 54462
@server_capability has_total_bytes_in_progress 54463
@server_capability has_timezone_updates 54464
@server_capability has_table_read_only_check 54467
@server_capability has_rows_before_aggregation 54469
@server_capability has_chunked_packets 54470
@server_capability has_versioned_parallel_replicas_protocol 54471
@server_capability has_interserver_external_roles 54472
@server_capability has_server_settings 54474
@server_capability has_query_and_line_numbers 54475
@server_capability has_jwt_in_interserver 54476
@server_capability has_query_plan_serialization 54477
@server_capability has_versioned_cluster_function_protocol 54479
@server_capability has_out_of_order_buckets_in_aggregation 54480
@server_capability has_compressed_logs_profile_events_columns 54481
@server_capability has_progress_in_async_insert 54484
@server_capability has_client_agent 54485

const CLIENT_NAME = "ClickHouseJL"
# Reference: ClickHouse v26.5.2-stable. TCP protocol revision is distinct from
# ClickHouse VERSION_REVISION.
const CLIENT_PROTOCOL_MAJOR = 26
const CLIENT_PROTOCOL_MINOR = 5
const CLIENT_PROTOCOL_PATCH = 2
const CLIENT_PROTOCOL_REVISION = 54485
const CLICKHOUSE_REFERENCE_VERSION = v"26.5.2"
const PARALLEL_REPLICAS_PROTOCOL_VERSION = 7
const CLUSTER_PROCESSING_PROTOCOL_VERSION = 6
const QUERY_PLAN_SERIALIZATION_VERSION = 1
const DBMS_DEFAULT_TCP_PORT = 9000
const DBMS_DEFAULT_SECURE_TCP_PORT = 9440
const DBMS_DEFAULT_BUFFER_SIZE = 1048576
const DBMS_DEFAULT_CONNECT_TIMEOUT = 5
const DBMS_DEFAULT_MAX_INSERT_BLOCK = 100000
const DBMS_DEFAULT_MAX_STRING_SIZE = 1 << 30
const DBMS_DEFAULT_MAX_COLUMN_SIZE_BYTES = 1 << 30
const DBMS_DEFAULT_MAX_COMPRESSED_BLOCK_SIZE = 1 << 30
const DBMS_DEFAULT_MAX_UNCOMPRESSED_BLOCK_SIZE = 1 << 30

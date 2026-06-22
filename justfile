container := "clickhouseclient-dev"
image := env_var_or_default("CLICKHOUSE_IMAGE", "clickhouse/clickhouse-server:25.3")

start:
    docker run --rm -d --name {{container}} --ulimit nofile=262144:262144 -e CLICKHOUSE_SKIP_USER_SETUP=1 -p 9000:9000 -p 8123:8123 {{image}}

stop:
    -docker stop {{container}}

restart: stop start

logs:
    docker logs -f {{container}}

status:
    docker ps --filter name={{container}}

client:
    docker exec -it {{container}} clickhouse-client

test-unit:
    julia --project=. test/unit/runtests.jl

test-integration:
    CLICKHOUSECLIENT_TEST_LIVE=1 julia --project=. test/integration/runtests.jl

test-all: test-unit test-integration

bench:
    julia --project=. benchmarks/run.jl

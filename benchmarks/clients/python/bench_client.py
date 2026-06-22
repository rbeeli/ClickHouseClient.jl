#!/usr/bin/env python3

import argparse
import datetime as dt
import json
import statistics
import sys
import time


COLUMNS = [
    "id",
    "ts",
    "user_id",
    "category",
    "metric",
    "country",
    "nullable_score",
    "payload",
]


def table_schema(table):
    return f"""
        CREATE TABLE IF NOT EXISTS {table} (
            id UInt64,
            ts DateTime,
            user_id UInt64,
            category LowCardinality(String),
            metric Float64,
            country LowCardinality(String),
            nullable_score Nullable(Float64),
            payload String
        )
        ENGINE = Memory
    """


def make_rows(count):
    base = dt.datetime(2024, 1, 1)
    rows = []
    for n in range(count):
        rows.append(
            (
                n,
                base + dt.timedelta(seconds=n % 86400),
                n % 100000,
                f"cat_{n % 64}",
                float(n % 100000) / 100.0,
                f"country_{n % 24}",
                None if n % 10 == 0 else float(n % 10000) / 10.0,
                f"payload-{n}",
            )
        )
    return rows


def rows_to_columns(rows):
    return [[row[i] for row in rows] for i in range(len(COLUMNS))]


def percentile(values, p):
    if not values:
        return float("nan")
    idx = min(max(int(len(values) * p + 0.999999) - 1, 0), len(values) - 1)
    return sorted(values)[idx]


def result(client_name, scenario, rows, iterations, seconds, produced_rows):
    median = statistics.median(seconds)
    return {
        "client": client_name,
        "scenario": scenario,
        "iterations": iterations,
        "rows": rows,
        "produced_rows": max(produced_rows),
        "seconds": seconds,
        "min_seconds": min(seconds),
        "median_seconds": median,
        "p95_seconds": percentile(seconds, 0.95),
        "rows_per_second": rows / median,
    }


def measure(client_name, scenario, rows, iterations, setup, run):
    seconds = []
    produced = []
    setup()
    run()
    for _ in range(iterations):
        setup()
        start = time.perf_counter()
        produced.append(int(run()))
        seconds.append(time.perf_counter() - start)
    return result(client_name, scenario, rows, iterations, seconds, produced)


class ClickHouseConnectClient:
    name = "python clickhouse-connect"

    def __init__(self, args):
        import clickhouse_connect

        self.client = clickhouse_connect.get_client(
            host=args.host,
            port=args.http_port,
            username=args.user,
            password=args.password,
            database=args.database,
        )

    def command(self, sql):
        self.client.command(sql)

    def query(self, sql):
        return self.client.query(sql).result_rows

    def insert_rows(self, table, rows):
        self.client.insert(table, rows, column_names=COLUMNS)

    def insert_columns(self, table, columns):
        self.client.insert(table, columns, column_names=COLUMNS, column_oriented=True)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="localhost")
    parser.add_argument("--native-port", type=int, default=9000)
    parser.add_argument("--http-port", type=int, default=8123)
    parser.add_argument("--user", default="default")
    parser.add_argument("--password", default="")
    parser.add_argument("--database", default="")
    parser.add_argument("--read-table", required=True)
    parser.add_argument("--write-table", required=True)
    parser.add_argument("--rows", type=int, default=100000)
    parser.add_argument("--iterations", type=int, default=5)
    return parser.parse_args()


def main():
    args = parse_args()
    client = ClickHouseConnectClient(args)
    rows = make_rows(args.rows)
    columns = rows_to_columns(rows)
    results = []

    client.command(f"DROP TABLE IF EXISTS {args.write_table}")
    client.command(table_schema(args.write_table))
    try:
        results.append(
            measure(
                client.name,
                "read_scan_materialize",
                args.rows,
                args.iterations,
                lambda: None,
                lambda: len(
                    client.query(
                        f"""
                        SELECT id, ts, user_id, category, metric, country, nullable_score, payload
                        FROM {args.read_table}
                        ORDER BY id
                        LIMIT {args.rows}
                        """
                    )
                ),
            )
        )
        results.append(
            measure(
                client.name,
                "read_group_aggregate",
                args.rows,
                args.iterations,
                lambda: None,
                lambda: len(
                    client.query(
                        f"""
                        SELECT
                            category,
                            country,
                            count() AS rows,
                            avg(metric) AS avg_metric,
                            toFloat64(quantileTDigest(0.95)(metric)) AS p95_metric
                        FROM {args.read_table}
                        GROUP BY category, country
                        ORDER BY category, country
                        """
                    )
                ),
            )
        )
        results.append(
            measure(
                client.name,
                "write_batch_insert",
                args.rows,
                args.iterations,
                lambda: client.command(f"TRUNCATE TABLE {args.write_table}"),
                lambda: client.insert_columns(args.write_table, columns) or args.rows,
            )
        )
        results.append(
            measure(
                client.name,
                "write_row_records",
                args.rows,
                args.iterations,
                lambda: client.command(f"TRUNCATE TABLE {args.write_table}"),
                lambda: client.insert_rows(args.write_table, rows) or args.rows,
            )
        )
    finally:
        client.command(f"DROP TABLE IF EXISTS {args.write_table}")

    json.dump(results, sys.stdout)


if __name__ == "__main__":
    main()

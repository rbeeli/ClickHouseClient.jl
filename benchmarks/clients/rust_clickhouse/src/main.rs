use std::collections::HashMap;
use std::env;
use std::time::Instant;

use chrono::{DateTime, Duration, TimeZone, Utc};
use clickhouse::{Client, Row};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Row, Serialize, Deserialize)]
struct Event {
    id: u64,
    #[serde(with = "clickhouse::serde::chrono::datetime")]
    ts: DateTime<Utc>,
    user_id: u64,
    category: String,
    metric: f64,
    country: String,
    nullable_score: Option<f64>,
    payload: String,
}

#[allow(dead_code)]
#[derive(Debug, Row, Deserialize)]
struct AggregateRow {
    category: String,
    country: String,
    rows: u64,
    avg_metric: f64,
    p95_metric: f64,
}

#[derive(Serialize)]
struct BenchResult {
    client: &'static str,
    scenario: &'static str,
    iterations: usize,
    rows: usize,
    produced_rows: usize,
    seconds: Vec<f64>,
    min_seconds: f64,
    median_seconds: f64,
    p95_seconds: f64,
    rows_per_second: f64,
}

struct Options {
    host: String,
    http_port: String,
    user: String,
    password: String,
    database: String,
    read_table: String,
    write_table: String,
    rows: usize,
    iterations: usize,
}

fn parse_args() -> Options {
    let mut opts = HashMap::from([
        ("host".to_string(), "localhost".to_string()),
        ("http-port".to_string(), "8123".to_string()),
        ("user".to_string(), "default".to_string()),
        ("password".to_string(), String::new()),
        ("database".to_string(), String::new()),
        ("read-table".to_string(), String::new()),
        ("write-table".to_string(), String::new()),
        ("rows".to_string(), "100000".to_string()),
        ("iterations".to_string(), "5".to_string()),
    ]);

    let args: Vec<String> = env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        let arg = &args[i];
        if let Some(key) = arg.strip_prefix("--") {
            if i + 1 >= args.len() {
                panic!("missing value for {arg}");
            }
            opts.insert(key.to_string(), args[i + 1].clone());
            i += 2;
        } else {
            panic!("unexpected argument: {arg}");
        }
    }

    let read_table = opts.remove("read-table").unwrap();
    let write_table = opts.remove("write-table").unwrap();
    if read_table.is_empty() || write_table.is_empty() {
        panic!("--read-table and --write-table are required");
    }

    Options {
        host: opts.remove("host").unwrap(),
        http_port: opts.remove("http-port").unwrap(),
        user: opts.remove("user").unwrap(),
        password: opts.remove("password").unwrap(),
        database: opts.remove("database").unwrap(),
        read_table,
        write_table,
        rows: opts.remove("rows").unwrap().parse().unwrap(),
        iterations: opts.remove("iterations").unwrap().parse().unwrap(),
    }
}

fn table_schema(table: &str) -> String {
    format!(
        r#"
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
    "#
    )
}

fn make_rows(count: usize) -> Vec<Event> {
    let base = Utc.with_ymd_and_hms(2024, 1, 1, 0, 0, 0).unwrap();
    let mut rows = Vec::with_capacity(count);
    for n in 0..count {
        rows.push(Event {
            id: n as u64,
            ts: base + Duration::seconds((n % 86400) as i64),
            user_id: (n % 100000) as u64,
            category: format!("cat_{}", n % 64),
            metric: (n % 100000) as f64 / 100.0,
            country: format!("country_{}", n % 24),
            nullable_score: if n % 10 == 0 {
                None
            } else {
                Some((n % 10000) as f64 / 10.0)
            },
            payload: format!("payload-{n}"),
        });
    }
    rows
}

fn percentile(values: &[f64], p: f64) -> f64 {
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let mut idx = (sorted.len() as f64 * p).ceil() as usize;
    idx = idx.clamp(1, sorted.len());
    sorted[idx - 1]
}

fn median(values: &[f64]) -> f64 {
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = sorted.len();
    if n % 2 == 1 {
        sorted[n / 2]
    } else {
        (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }
}

async fn measure<S, R, SFut, RFut>(
    scenario: &'static str,
    rows: usize,
    iterations: usize,
    mut setup: S,
    mut run: R,
) -> anyhow::Result<BenchResult>
where
    S: FnMut() -> SFut,
    SFut: std::future::Future<Output = anyhow::Result<()>>,
    R: FnMut() -> RFut,
    RFut: std::future::Future<Output = anyhow::Result<usize>>,
{
    let mut seconds = Vec::with_capacity(iterations);
    let mut produced_rows = 0usize;

    setup().await?;
    run().await?;
    for _ in 0..iterations {
        setup().await?;
        let start = Instant::now();
        let produced = run().await?;
        seconds.push(start.elapsed().as_secs_f64());
        produced_rows = produced_rows.max(produced);
    }

    let med = median(&seconds);
    Ok(BenchResult {
        client: "rust clickhouse",
        scenario,
        iterations,
        rows,
        produced_rows,
        min_seconds: seconds.iter().copied().fold(f64::INFINITY, f64::min),
        median_seconds: med,
        p95_seconds: percentile(&seconds, 0.95),
        rows_per_second: rows as f64 / med,
        seconds,
    })
}

fn make_client(opts: &Options) -> Client {
    Client::default()
        .with_url(format!("http://{}:{}", opts.host, opts.http_port))
        .with_user(&opts.user)
        .with_password(&opts.password)
        .with_database(&opts.database)
}

async fn read_scan(client: &Client, table: &str, rows: usize) -> anyhow::Result<usize> {
    let sql = format!(
        r#"
        SELECT id, ts, user_id, category, metric, country, nullable_score, payload
        FROM {table}
        ORDER BY id
        LIMIT {rows}
        "#
    );
    let result = client.query(&sql).fetch_all::<Event>().await?;
    Ok(result.len())
}

async fn read_aggregate(client: &Client, table: &str) -> anyhow::Result<usize> {
    let sql = format!(
        r#"
        SELECT
            category,
            country,
            count() AS rows,
            avg(metric) AS avg_metric,
            toFloat64(quantileTDigest(0.95)(metric)) AS p95_metric
        FROM {table}
        GROUP BY category, country
        ORDER BY category, country
        "#
    );
    let result = client.query(&sql).fetch_all::<AggregateRow>().await?;
    Ok(result.len())
}

async fn insert_rows(client: &Client, table: &str, rows: &[Event]) -> anyhow::Result<usize> {
    let mut insert = client.insert::<Event>(table).await?;
    for row in rows {
        insert.write(row).await?;
    }
    insert.end().await?;
    Ok(rows.len())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let opts = parse_args();
    let client = make_client(&opts);
    let rows = make_rows(opts.rows);

    client
        .query(&format!("DROP TABLE IF EXISTS {}", opts.write_table))
        .execute()
        .await?;
    client
        .query(&table_schema(&opts.write_table))
        .execute()
        .await?;

    let mut results = Vec::with_capacity(4);
    results.push(
        measure(
            "read_scan_materialize",
            opts.rows,
            opts.iterations,
            || async { Ok(()) },
            || read_scan(&client, &opts.read_table, opts.rows),
        )
        .await?,
    );
    results.push(
        measure(
            "read_group_aggregate",
            opts.rows,
            opts.iterations,
            || async { Ok(()) },
            || read_aggregate(&client, &opts.read_table),
        )
        .await?,
    );
    results.push(
        measure(
            "write_batch_insert",
            opts.rows,
            opts.iterations,
            || async {
                client
                    .query(&format!("TRUNCATE TABLE {}", opts.write_table))
                    .execute()
                    .await?;
                Ok(())
            },
            || insert_rows(&client, &opts.write_table, &rows),
        )
        .await?,
    );
    results.push(
        measure(
            "write_row_records",
            opts.rows,
            opts.iterations,
            || async {
                client
                    .query(&format!("TRUNCATE TABLE {}", opts.write_table))
                    .execute()
                    .await?;
                Ok(())
            },
            || insert_rows(&client, &opts.write_table, &rows),
        )
        .await?,
    );

    client
        .query(&format!("DROP TABLE IF EXISTS {}", opts.write_table))
        .execute()
        .await?;
    println!("{}", serde_json::to_string(&results)?);
    Ok(())
}

package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"sort"
	"time"

	clickhouse "github.com/ClickHouse/clickhouse-go/v2"
)

var columns = []string{
	"id",
	"ts",
	"user_id",
	"category",
	"metric",
	"country",
	"nullable_score",
	"payload",
}

type event struct {
	ID       uint64
	TS       time.Time
	UserID   uint64
	Category string
	Metric   float64
	Country  string
	Score    *float64
	Payload  string
}

type result struct {
	Client        string    `json:"client"`
	Scenario      string    `json:"scenario"`
	Iterations    int       `json:"iterations"`
	Rows          int       `json:"rows"`
	ProducedRows  int       `json:"produced_rows"`
	Seconds       []float64 `json:"seconds"`
	MinSeconds    float64   `json:"min_seconds"`
	MedianSeconds float64   `json:"median_seconds"`
	P95Seconds    float64   `json:"p95_seconds"`
	RowsPerSecond float64   `json:"rows_per_second"`
}

type options struct {
	host       string
	port       int
	user       string
	password   string
	database   string
	readTable  string
	writeTable string
	rows       int
	iterations int
}

func tableSchema(table string) string {
	return fmt.Sprintf(`
		CREATE TABLE IF NOT EXISTS %s (
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
	`, table)
}

func makeRows(count int) []event {
	base := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC)
	rows := make([]event, count)
	for i := 0; i < count; i++ {
		var score *float64
		if i%10 != 0 {
			value := float64(i%10000) / 10.0
			score = &value
		}
		rows[i] = event{
			ID:       uint64(i),
			TS:       base.Add(time.Duration(i%86400) * time.Second),
			UserID:   uint64(i % 100000),
			Category: fmt.Sprintf("cat_%d", i%64),
			Metric:   float64(i%100000) / 100.0,
			Country:  fmt.Sprintf("country_%d", i%24),
			Score:    score,
			Payload:  fmt.Sprintf("payload-%d", i),
		}
	}
	return rows
}

func median(values []float64) float64 {
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	n := len(sorted)
	if n%2 == 1 {
		return sorted[n/2]
	}
	return (sorted[n/2-1] + sorted[n/2]) / 2
}

func percentile(values []float64, p float64) float64 {
	sorted := append([]float64(nil), values...)
	sort.Float64s(sorted)
	idx := int(float64(len(sorted))*p + 0.999999)
	if idx < 1 {
		idx = 1
	}
	if idx > len(sorted) {
		idx = len(sorted)
	}
	return sorted[idx-1]
}

func min(values []float64) float64 {
	best := values[0]
	for _, value := range values[1:] {
		if value < best {
			best = value
		}
	}
	return best
}

func measure(scenario string, rows int, iterations int, setup func() error, run func() (int, error)) (result, error) {
	seconds := make([]float64, 0, iterations)
	produced := 0
	if err := setup(); err != nil {
		return result{}, err
	}
	if _, err := run(); err != nil {
		return result{}, err
	}
	for i := 0; i < iterations; i++ {
		if err := setup(); err != nil {
			return result{}, err
		}
		start := time.Now()
		n, err := run()
		if err != nil {
			return result{}, err
		}
		seconds = append(seconds, time.Since(start).Seconds())
		if n > produced {
			produced = n
		}
	}
	med := median(seconds)
	return result{
		Client:        "go clickhouse-go/v2",
		Scenario:      scenario,
		Iterations:    iterations,
		Rows:          rows,
		ProducedRows:  produced,
		Seconds:       seconds,
		MinSeconds:    min(seconds),
		MedianSeconds: med,
		P95Seconds:    percentile(seconds, 0.95),
		RowsPerSecond: float64(rows) / med,
	}, nil
}

func connect(ctx context.Context, opts options) (clickhouse.Conn, error) {
	conn, err := clickhouse.Open(&clickhouse.Options{
		Addr: []string{fmt.Sprintf("%s:%d", opts.host, opts.port)},
		Auth: clickhouse.Auth{
			Database: opts.database,
			Username: opts.user,
			Password: opts.password,
		},
	})
	if err != nil {
		return nil, err
	}
	if err := conn.Ping(ctx); err != nil {
		return nil, err
	}
	return conn, nil
}

func scanRead(ctx context.Context, conn clickhouse.Conn, table string, rows int) (int, error) {
	sql := fmt.Sprintf(`
		SELECT id, ts, user_id, category, metric, country, nullable_score, payload
		FROM %s
		ORDER BY id
		LIMIT %d
	`, table, rows)
	rs, err := conn.Query(ctx, sql)
	if err != nil {
		return 0, err
	}
	defer rs.Close()

	events := make([]event, 0, rows)
	for rs.Next() {
		var e event
		if err := rs.Scan(
			&e.ID,
			&e.TS,
			&e.UserID,
			&e.Category,
			&e.Metric,
			&e.Country,
			&e.Score,
			&e.Payload,
		); err != nil {
			return 0, err
		}
		events = append(events, e)
	}
	return len(events), rs.Err()
}

func aggregateRead(ctx context.Context, conn clickhouse.Conn, table string) (int, error) {
	sql := fmt.Sprintf(`
		SELECT
			category,
			country,
			count() AS rows,
			avg(metric) AS avg_metric,
			toFloat64(quantileTDigest(0.95)(metric)) AS p95_metric
		FROM %s
		GROUP BY category, country
		ORDER BY category, country
	`, table)
	rs, err := conn.Query(ctx, sql)
	if err != nil {
		return 0, err
	}
	defer rs.Close()

	type agg struct {
		category string
		country  string
		rows     uint64
		avg      float64
		p95      float64
	}
	values := make([]agg, 0, 2048)
	for rs.Next() {
		var value agg
		if err := rs.Scan(&value.category, &value.country, &value.rows, &value.avg, &value.p95); err != nil {
			return 0, err
		}
		values = append(values, value)
	}
	return len(values), rs.Err()
}

func insertBatch(ctx context.Context, conn clickhouse.Conn, table string, rows []event) (int, error) {
	batch, err := conn.PrepareBatch(ctx, fmt.Sprintf("INSERT INTO %s", table))
	if err != nil {
		return 0, err
	}
	for _, row := range rows {
		if err := batch.Append(
			row.ID,
			row.TS,
			row.UserID,
			row.Category,
			row.Metric,
			row.Country,
			row.Score,
			row.Payload,
		); err != nil {
			return 0, err
		}
	}
	if err := batch.Send(); err != nil {
		return 0, err
	}
	return len(rows), nil
}

func parseOptions() options {
	var opts options
	flag.StringVar(&opts.host, "host", "localhost", "ClickHouse host")
	flag.IntVar(&opts.port, "port", 9000, "ClickHouse native TCP port")
	flag.StringVar(&opts.user, "user", "default", "ClickHouse user")
	flag.StringVar(&opts.password, "password", "", "ClickHouse password")
	flag.StringVar(&opts.database, "database", "", "ClickHouse database")
	flag.StringVar(&opts.readTable, "read-table", "", "preloaded read table")
	flag.StringVar(&opts.writeTable, "write-table", "", "benchmark write table")
	flag.IntVar(&opts.rows, "rows", 100000, "rows per workload")
	flag.IntVar(&opts.iterations, "iterations", 5, "timed iterations")
	flag.Parse()
	if opts.readTable == "" || opts.writeTable == "" {
		fmt.Fprintln(os.Stderr, "--read-table and --write-table are required")
		os.Exit(2)
	}
	return opts
}

func main() {
	ctx := context.Background()
	opts := parseOptions()
	conn, err := connect(ctx, opts)
	if err != nil {
		panic(err)
	}
	rows := makeRows(opts.rows)
	results := make([]result, 0, 4)

	if err := conn.Exec(ctx, fmt.Sprintf("DROP TABLE IF EXISTS %s", opts.writeTable)); err != nil {
		panic(err)
	}
	if err := conn.Exec(ctx, tableSchema(opts.writeTable)); err != nil {
		panic(err)
	}
	defer conn.Exec(ctx, fmt.Sprintf("DROP TABLE IF EXISTS %s", opts.writeTable))

	tests := []struct {
		scenario string
		setup    func() error
		run      func() (int, error)
	}{
		{
			scenario: "read_scan_materialize",
			setup:    func() error { return nil },
			run:      func() (int, error) { return scanRead(ctx, conn, opts.readTable, opts.rows) },
		},
		{
			scenario: "read_group_aggregate",
			setup:    func() error { return nil },
			run:      func() (int, error) { return aggregateRead(ctx, conn, opts.readTable) },
		},
		{
			scenario: "write_batch_insert",
			setup:    func() error { return conn.Exec(ctx, fmt.Sprintf("TRUNCATE TABLE %s", opts.writeTable)) },
			run:      func() (int, error) { return insertBatch(ctx, conn, opts.writeTable, rows) },
		},
		{
			scenario: "write_row_records",
			setup:    func() error { return conn.Exec(ctx, fmt.Sprintf("TRUNCATE TABLE %s", opts.writeTable)) },
			run:      func() (int, error) { return insertBatch(ctx, conn, opts.writeTable, rows) },
		},
	}

	for _, test := range tests {
		res, err := measure(test.scenario, opts.rows, opts.iterations, test.setup, test.run)
		if err != nil {
			panic(err)
		}
		results = append(results, res)
	}

	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(results); err != nil {
		panic(err)
	}
}

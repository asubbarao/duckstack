-- One-time copy of the OpenTelemetry rows dev's main schema collected before otlp_serve wrote to the lake.
-- Run once on dev (MCP execute), after dev boots the setup.sql that streams into lake.otel and before dev.duckdb is
-- reset. From then on main.otlp_* receive nothing, so the copy does not overlap the rows streaming into lake.otel.
-- Column names, types and order are identical in both (127 columns over 6 tables, checked 2026-10-15).
INSERT INTO lake.otel.otlp_logs BY NAME SELECT * FROM dev.main.otlp_logs;
INSERT INTO lake.otel.otlp_traces BY NAME SELECT * FROM dev.main.otlp_traces;
INSERT INTO lake.otel.otlp_metrics_sum BY NAME SELECT * FROM dev.main.otlp_metrics_sum;
INSERT INTO lake.otel.otlp_metrics_gauge BY NAME SELECT * FROM dev.main.otlp_metrics_gauge;
INSERT INTO lake.otel.otlp_metrics_histogram BY NAME SELECT * FROM dev.main.otlp_metrics_histogram;
INSERT INTO lake.otel.otlp_metrics_exp_histogram BY NAME SELECT * FROM dev.main.otlp_metrics_exp_histogram;

-- Check before the reset: copied is true on every row (the lake also holds the rows streamed since the deploy).
WITH dev AS (
    SELECT 'otlp_logs' AS t, count(time_unix_nano) AS rows FROM dev.main.otlp_logs
    UNION ALL SELECT 'otlp_traces', count(start_time_unix_nano) FROM dev.main.otlp_traces
    UNION ALL SELECT 'otlp_metrics_sum', count(time_unix_nano) FROM dev.main.otlp_metrics_sum
    UNION ALL SELECT 'otlp_metrics_gauge', count(time_unix_nano) FROM dev.main.otlp_metrics_gauge
    UNION ALL SELECT 'otlp_metrics_histogram', count(time_unix_nano) FROM dev.main.otlp_metrics_histogram
    UNION ALL SELECT 'otlp_metrics_exp_histogram', count(time_unix_nano) FROM dev.main.otlp_metrics_exp_histogram
), lake AS (
    SELECT 'otlp_logs' AS t, count(time_unix_nano) AS rows FROM lake.otel.otlp_logs
    UNION ALL SELECT 'otlp_traces', count(start_time_unix_nano) FROM lake.otel.otlp_traces
    UNION ALL SELECT 'otlp_metrics_sum', count(time_unix_nano) FROM lake.otel.otlp_metrics_sum
    UNION ALL SELECT 'otlp_metrics_gauge', count(time_unix_nano) FROM lake.otel.otlp_metrics_gauge
    UNION ALL SELECT 'otlp_metrics_histogram', count(time_unix_nano) FROM lake.otel.otlp_metrics_histogram
    UNION ALL SELECT 'otlp_metrics_exp_histogram', count(time_unix_nano) FROM lake.otel.otlp_metrics_exp_histogram
)
SELECT t, dev.rows AS dev_rows, lake.rows AS lake_rows, lake.rows >= dev.rows AS copied
FROM dev JOIN lake USING (t) ORDER BY t;

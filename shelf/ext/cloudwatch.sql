-- @ext: cloudwatch
-- @rev: d404b01 (community, DuckDB 1.5.5); on the dev server (setup.sql) and the local client
-- @verified: 2026-09-17 — loads; the read fails cleanly without credentials ("Secret Validation Failure … credential_chain")
--   Inventory verified via boto3 the same day: 49 log groups in us-west-2, 365-day retention.
-- @functions: read_cloudwatch_logs, read_cloudwatch_logs_insights, read_cloudwatch_metrics, read_cloudwatch_service_dependencies, ATTACH 'cloudwatch:', send_cloudwatch_logs, send_cloudwatch_metrics
-- @needs: aws + httpfs loaded; `aws login` (SSO) on the Mac; a TYPE aws secret with REGION
-- @tags: logs, ecs, rds, alarms, metrics, otlp, prod, window, 1 hour, 1 day, backfill
-- @summary: CloudWatch Logs/Metrics/Alarms as OTLP-shaped tables. Window is a parameter ('-1h', '-1d',
--   ISO, epoch ms); one pull per window, landed whole, day-partitioned.
LOAD aws; LOAD cloudwatch;
CREATE SECRET prod_cw (TYPE aws, PROVIDER credential_chain, REGION 'us-west-2');   -- picks up `aws login`

-- The window is the only knob. '-1h' for the hourly pull, '-1d' for the daily, ISO pairs for a backfill day.
SET VARIABLE win_start = '-1h';
SET VARIABLE win_end   = 'now';

-- read_cloudwatch_logs(log_group, start_time := '-15m', end_time := 'now', filter := '', log_stream_prefix := '',
--                      log_streams := [], "order" := 'asc', page_size, max_rows, secret, region, endpoint, retries, timeout)
--   -> 18 OTLP log columns; populated: time_unix_nano, observed_time_unix_nano, body, resource_attributes (JSON:
--      aws.log.group.names, aws.log.stream.names), log_attributes. Stream = ECS task id.
CREATE TEMP TABLE cw AS
SELECT g.log_group, l.*
FROM (VALUES ('/ecs/inframe-production/backend'), ('/ecs/inframe-production/worker-default'),
             ('/ecs/inframe-production/worker-critical'), ('/aws/rds/instance/inframe-production-db/postgresql')) g(log_group),
     LATERAL read_cloudwatch_logs(g.log_group, start_time => getvariable('win_start'), end_time => getvariable('win_end'), secret => 'prod_cw') l;

SELECT log_group, resource_attributes->>'aws.log.stream.names' AS stream, count(*) AS lines, min(time_unix_nano), max(time_unix_nano)
FROM cw GROUP BY ALL ORDER BY 1, 3 DESC;

-- Land once per day; FILENAME_PATTERN 'part' makes the write idempotent (part0.parquet per partition).
COPY (SELECT *, date_trunc('day', time_unix_nano)::DATE AS day FROM cw)
  TO 'scratch/cw' (FORMAT parquet, PARTITION_BY (log_group, day), OVERWRITE_OR_IGNORE, FILENAME_PATTERN 'part');

-- Backfill = the same statement with ISO bounds, one day at a time (FilterLogEvents pages; keep windows ≤ 1 day):
--   SET VARIABLE win_start = '2026-09-15T00:00:00Z'; SET VARIABLE win_end = '2026-09-16T00:00:00Z';

-- Server-side aggregation when volume is high (10k rows / 50 groups cap; all-VARCHAR result):
FROM read_cloudwatch_logs_insights('stats count(*) by bin(5m), @logStream', log_groups => ['/ecs/inframe-production/backend'],
                                   start_time => '-1d', secret => 'prod_cw');

-- Metrics (GetMetricData; relative times s/m/h/d only, no weeks, no epoch-ms here):
FROM read_cloudwatch_metrics('AWS/ECS', 'RunningTaskCount',
     dimensions => MAP {'ClusterName': 'inframe-production', 'ServiceName': 'inframe-production-backend'},
     statistic => 'Maximum', period => 60, start_time => '-6h', secret => 'prod_cw');

-- Catalog form: alarms currently ALARM / INSUFFICIENT_DATA, logs.* per attached group
ATTACH 'cloudwatch:' AS cwc (TYPE cloudwatch, SECRET 'prod_cw', LOG_GROUPS ['/ecs/inframe-production/backend']);
FROM cwc.alerts.open;

-- The bodies are python JSON lines + uvicorn access lines: parse with duck_hunt (see ext/duck_hunt.sql, inframe_backend parser).
-- Prod groups (bytes stored, 2026-09-17): backend 1.66 GB · worker-default 622 MB · worker-critical 145 MB · frontend 469 MB
--   · adot 1.6 MB · rds postgresql 1.10 GB · vpc flow-logs 15 GB · cloudtrail 4.8 GB · containerinsights 1.67 GB.
-- Amazon Managed Prometheus workspaces: inframe-production ws-2da783c8-675f-4528-8061-aaea454245a1 (also staging, demo). No Managed Grafana.

-- Native observability over DuckDB's own log (duckdb_logs reads the CSV setup.sql logs to; no archive, no ATTACH).
-- Quack already records the request, duration, response class and error; keep that shape.
CREATE OR REPLACE VIEW meta.quack_events AS
SELECT * EXCLUDE (message), unnest(parse_duckdb_log_message('Quack', message))
FROM duckdb_logs
WHERE type = 'Quack';

CREATE OR REPLACE VIEW meta.remote_query_history AS
SELECT timestamp AS started_at,
       quack_connection_id,
       client_query_id,
       query,
       duration_ms,
       duration_ms / 1000.0 AS wall_seconds,
       response_type,
       error
FROM meta.quack_events
WHERE message_type = 'PREPARE_REQUEST'
  AND server IS NULL
  AND client_query_id IS NOT NULL;

CREATE OR REPLACE VIEW meta.query_errors AS
FROM meta.remote_query_history
WHERE error IS NOT NULL;

CREATE OR REPLACE VIEW meta.slow_queries AS
FROM meta.remote_query_history
WHERE duration_ms >= 1000;

CREATE OR REPLACE VIEW meta.query_minute AS
SELECT time_bucket(INTERVAL 1 MINUTE, started_at) AS minute,
       len(list(started_at)) AS queries,
       len(list(started_at) FILTER (error IS NOT NULL)) AS errors,
       quantile_cont(duration_ms, 0.50) AS p50_ms,
       quantile_cont(duration_ms, 0.95) AS p95_ms,
       quantile_cont(duration_ms, 0.99) AS p99_ms,
       max(duration_ms) AS max_ms,
       sum(duration_ms) / 1000.0 AS wall_seconds
FROM meta.remote_query_history
GROUP BY ALL;

-- ShellFS supplies the host view, while the route reads only this retained SQL table.
CREATE TABLE IF NOT EXISTS meta.host_process_samples (
  observed_at TIMESTAMPTZ,
  pid BIGINT,
  ppid BIGINT,
  role VARCHAR,
  elapsed VARCHAR,
  cpu_percent DOUBLE,
  memory_percent DOUBLE,
  command VARCHAR
);

DELETE FROM meta.host_process_samples WHERE observed_at < now() - INTERVAL 7 DAY;
INSERT INTO meta.host_process_samples BY NAME
SELECT now() AS observed_at, pid, ppid,
       CASE
         WHEN ppid = 1 AND command = '/opt/homebrew/bin/duckdb' THEN 'agent_reader'
         WHEN ppid <> 1 AND command = '/opt/homebrew/bin/duckdb' THEN 'system_quack'
         ELSE 'duckdb_client'
       END AS role,
       elapsed, cpu_percent, memory_percent, command
FROM agents.host_processes()
WHERE command IN ('duckdb', '/opt/homebrew/bin/duckdb');

CREATE OR REPLACE VIEW meta.host_process_latest AS
SELECT * FROM meta.host_process_samples
QUALIFY observed_at = max(observed_at) OVER ();

CREATE OR REPLACE TEMP TABLE _observability_process_job AS
SELECT 'DELETE FROM meta.host_process_samples WHERE observed_at < now() - INTERVAL 7 DAY;
INSERT INTO meta.host_process_samples BY NAME
SELECT now() AS observed_at, pid, ppid,
       CASE
         WHEN ppid = 1 AND command = ''/opt/homebrew/bin/duckdb'' THEN ''agent_reader''
         WHEN ppid <> 1 AND command = ''/opt/homebrew/bin/duckdb'' THEN ''system_quack''
         ELSE ''duckdb_client''
       END AS role,
       elapsed, cpu_percent, memory_percent, command
FROM agents.host_processes()
WHERE command IN (''duckdb'', ''/opt/homebrew/bin/duckdb'');
CREATE OR REPLACE TABLE meta.prometheus_snapshot AS
SELECT now() AS observed_at, text FROM meta.prometheus_metrics;' AS query,
       '0 * * * * *' AS schedule;

SELECT cron_delete(j.job_id)
FROM cron_jobs() j CROSS JOIN _observability_process_job p
WHERE j.query GLOB '*meta.host_process_samples*'
  AND trim(j.query) IS DISTINCT FROM trim(p.query);

SELECT cron(query, schedule)
FROM _observability_process_job
WHERE (trim(query), schedule) NOT IN (SELECT trim(query), schedule FROM cron_jobs());

-- A single `text` column is emitted by quackapi as text/plain, which Prometheus can scrape.
CREATE OR REPLACE VIEW meta.prometheus_metrics AS
WITH query_totals AS (
  SELECT len(list(started_at)) AS queries,
         len(list(started_at) FILTER (error IS NOT NULL)) AS errors,
         sum(duration_ms) / 1000.0 AS wall_seconds
  FROM meta.remote_query_history
), archive AS (
  SELECT greatest(0, date_diff('millisecond', max(timestamp), now()) / 1000.0) AS lag_seconds
  FROM duckdb_logs
), memory AS (
  SELECT sum(memory_usage_bytes) AS tracked_bytes,
         sum(temporary_storage_bytes) AS temporary_bytes,
         string_agg(printf('duckdb_memory_usage_bytes{tag="%s"} %d', tag, memory_usage_bytes), chr(10)
                    ORDER BY tag) AS tag_lines
  FROM duckdb_memory()
), processes AS (
  SELECT len(list(pid)) AS process_count,
         sum(memory_percent) AS memory_percent,
         coalesce(max(memory_percent) FILTER (role = 'agent_reader'), 0) AS agent_reader_memory_percent,
         coalesce(max(memory_percent) FILTER (role = 'system_quack'), 0) AS system_quack_memory_percent
  FROM meta.host_process_latest
)
SELECT concat(
  '# HELP duckdb_quack_queries_total Quack queries archived by DuckDB.', chr(10),
  '# TYPE duckdb_quack_queries_total counter', chr(10),
  'duckdb_quack_queries_total ', queries, chr(10),
  '# HELP duckdb_quack_query_errors_total Quack query errors archived by DuckDB.', chr(10),
  '# TYPE duckdb_quack_query_errors_total counter', chr(10),
  'duckdb_quack_query_errors_total ', errors, chr(10),
  '# HELP duckdb_quack_query_wall_seconds_total Total Quack query wall time.', chr(10),
  '# TYPE duckdb_quack_query_wall_seconds_total counter', chr(10),
  'duckdb_quack_query_wall_seconds_total ', wall_seconds, chr(10),
  '# HELP duckdb_query_archive_lag_seconds Age of the newest archived native log row.', chr(10),
  '# TYPE duckdb_query_archive_lag_seconds gauge', chr(10),
  'duckdb_query_archive_lag_seconds ', lag_seconds, chr(10),
  '# HELP duckdb_memory_tracked_bytes Memory tracked by DuckDB memory managers.', chr(10),
  '# TYPE duckdb_memory_tracked_bytes gauge', chr(10),
  'duckdb_memory_tracked_bytes ', tracked_bytes, chr(10),
  '# HELP duckdb_temporary_storage_bytes Temporary storage tracked by DuckDB.', chr(10),
  '# TYPE duckdb_temporary_storage_bytes gauge', chr(10),
  'duckdb_temporary_storage_bytes ', temporary_bytes, chr(10),
  '# HELP duckdb_memory_usage_bytes DuckDB tracked memory by internal tag.', chr(10),
  '# TYPE duckdb_memory_usage_bytes gauge', chr(10),
  tag_lines, chr(10),
  '# HELP duckdb_processes Processes whose executable is DuckDB.', chr(10),
  '# TYPE duckdb_processes gauge', chr(10),
  'duckdb_processes ', process_count, chr(10),
  '# HELP duckdb_process_memory_percent_sum Host memory percent used by DuckDB processes.', chr(10),
  '# TYPE duckdb_process_memory_percent_sum gauge', chr(10),
  'duckdb_process_memory_percent_sum ', memory_percent, chr(10),
  'duckdb_agent_reader_memory_percent ', agent_reader_memory_percent, chr(10),
  'duckdb_system_quack_memory_percent ', system_quack_memory_percent, chr(10)
) AS text
FROM query_totals CROSS JOIN archive CROSS JOIN memory CROSS JOIN processes;

CREATE OR REPLACE TABLE meta.prometheus_snapshot AS
SELECT now() AS observed_at, text FROM meta.prometheus_metrics;

CREATE OR REPLACE ROUTE prometheus_metrics GET '/metrics'
AS SELECT text FROM meta.prometheus_snapshot;

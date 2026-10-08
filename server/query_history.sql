-- Rebuildable compatibility views over native logs; no DuckLake backup.
CREATE OR REPLACE VIEW meta.query_log AS
SELECT * EXCLUDE (type, message), message AS query
FROM duckdb_logs
WHERE type = 'QueryLog';

CREATE OR REPLACE VIEW meta.query_metrics AS
SELECT * EXCLUDE (message), unnest(parse_duckdb_log_message('Metrics', message))
FROM duckdb_logs
WHERE type = 'Metrics';

CREATE OR REPLACE VIEW meta.remote_queries AS
SELECT * EXCLUDE (message), unnest(parse_duckdb_log_message('Quack', message))
FROM duckdb_logs
WHERE type = 'Quack' AND parse_duckdb_log_message('Quack', message).message_type = 'PREPARE_REQUEST';

CREATE OR REPLACE VIEW meta.query_history AS
WITH metric_rows AS (
  SELECT q.timestamp AS query_started_at, q.context_id, q.connection_id, q.query_id,
         m.metric, m.value
  FROM meta.query_metrics m
  ASOF JOIN meta.query_log q
    ON m.context_id = q.context_id
   AND m.connection_id = q.connection_id
   AND m.query_id = q.query_id
   AND m.timestamp >= q.timestamp
), query_cost AS (
  SELECT query_started_at, context_id, connection_id, query_id,
         max(try_cast(value AS DOUBLE)) FILTER (metric = 'LATENCY') AS wall_seconds,
         max(try_cast(value AS DOUBLE)) FILTER (metric = 'CPU_TIME') AS cpu_seconds,
         max(try_cast(value AS UBIGINT)) FILTER (metric = 'ROWS_RETURNED') AS rows_returned,
         max(try_cast(value AS UBIGINT)) FILTER (metric = 'TOTAL_BYTES_READ') AS bytes_read,
         max(try_cast(value AS UBIGINT)) FILTER (metric = 'TOTAL_BYTES_WRITTEN') AS bytes_written,
         max(try_cast(value AS UBIGINT)) FILTER (metric = 'SYSTEM_PEAK_BUFFER_MEMORY') AS system_peak_buffer_bytes,
         max(try_cast(value AS UBIGINT)) FILTER (metric = 'SYSTEM_PEAK_TEMP_DIR_SIZE') AS system_peak_temp_bytes
  FROM metric_rows
  GROUP BY ALL
)
SELECT q.*, c.* EXCLUDE (query_started_at, context_id, connection_id, query_id)
FROM meta.query_log q
LEFT JOIN query_cost c
  ON q.timestamp = c.query_started_at
 AND q.context_id = c.context_id
 AND q.connection_id = c.connection_id
 AND q.query_id = c.query_id;

CREATE OR REPLACE MACRO meta.queries_between(start_at, end_at) AS TABLE
WITH queries AS (
  SELECT * FROM meta.query_log
  WHERE timestamp >= start_at AND timestamp < end_at
), metrics AS (
  SELECT * FROM meta.query_metrics
  WHERE timestamp >= start_at AND timestamp < end_at + INTERVAL 1 DAY
), metric_rows AS (
  SELECT q.timestamp AS query_started_at, q.context_id, q.connection_id, q.query_id,
         m.metric, m.value
  FROM metrics m
  ASOF JOIN queries q
    ON m.context_id = q.context_id
   AND m.connection_id = q.connection_id
   AND m.query_id = q.query_id
   AND m.timestamp >= q.timestamp
), query_cost AS (
  SELECT query_started_at, context_id, connection_id, query_id,
         max(try_cast(value AS DOUBLE)) FILTER (metric = 'LATENCY') AS wall_seconds,
         max(try_cast(value AS DOUBLE)) FILTER (metric = 'CPU_TIME') AS cpu_seconds,
         max(try_cast(value AS UBIGINT)) FILTER (metric = 'ROWS_RETURNED') AS rows_returned,
         max(try_cast(value AS UBIGINT)) FILTER (metric = 'TOTAL_BYTES_READ') AS bytes_read,
         max(try_cast(value AS UBIGINT)) FILTER (metric = 'TOTAL_BYTES_WRITTEN') AS bytes_written,
         max(try_cast(value AS UBIGINT)) FILTER (metric = 'SYSTEM_PEAK_BUFFER_MEMORY') AS system_peak_buffer_bytes,
         max(try_cast(value AS UBIGINT)) FILTER (metric = 'SYSTEM_PEAK_TEMP_DIR_SIZE') AS system_peak_temp_bytes
  FROM metric_rows
  GROUP BY ALL
)
SELECT q.*, c.* EXCLUDE (query_started_at, context_id, connection_id, query_id)
FROM queries q
LEFT JOIN query_cost c
  ON q.timestamp = c.query_started_at
 AND q.context_id = c.context_id
 AND q.connection_id = c.connection_id
 AND q.query_id = c.query_id;

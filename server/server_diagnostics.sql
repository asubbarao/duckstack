-- Raw OS evidence survives a native crash; all interpretation remains in views.
CREATE SCHEMA IF NOT EXISTS meta;
-- CSVs include the final statements of processes that died before the archive cron ran.
CREATE OR REPLACE VIEW meta.native_logs AS
SELECT * FROM read_csv(getenv('HOME') || '/.duck/logs/duckdb_log*.csv',
    header := true, union_by_name := true, filename := true,
    max_line_size := 16777216,
    columns := {context_id: 'UBIGINT', scope: 'VARCHAR', connection_id: 'UBIGINT',
                transaction_id: 'UBIGINT', query_id: 'UBIGINT', thread_id: 'UBIGINT',
                timestamp: 'TIMESTAMPTZ', type: 'VARCHAR', log_level: 'VARCHAR', message: 'VARCHAR'});

CREATE OR REPLACE VIEW meta.server_query_log AS
SELECT i.instance_id, l.* FROM meta.native_logs l
LEFT JOIN meta.server_instances i ON l.filename = i.native_log_path
WHERE l.type = 'QueryLog';

CREATE OR REPLACE VIEW meta.server_events AS
SELECT f.file, l.line_number, l.content AS raw_line,
       try_cast(l.content AS JSON) AS event
FROM glob(getenv('HOME') || '/.duck/logs/server-events*.jsonl') f
CROSS JOIN LATERAL read_lines_lateral(f.file) l;

CREATE OR REPLACE VIEW meta.server_crash_files AS
SELECT file, file_size(file) AS bytes, file_last_modified(file) AS modified_at
FROM glob(getenv('HOME') || '/Library/Logs/DiagnosticReports/duckdb-*.ips');

CREATE OR REPLACE VIEW meta.server_crashes AS
WITH documents AS (
    SELECT f.file,
           string_agg(l.content, '' ORDER BY l.line_number) AS raw_report,
           string_agg(l.content, '' ORDER BY l.line_number)
               FILTER (WHERE l.line_number = 1)::JSON AS header,
           try_cast(string_agg(l.content, '' ORDER BY l.line_number)
               FILTER (WHERE l.line_number > 1) AS JSON) AS report
    FROM meta.server_crash_files f
    CROSS JOIN LATERAL read_lines_lateral(f.file) l
    GROUP BY f.file
)
SELECT *, try_cast(report->>'pid' AS BIGINT) AS pid,
       try_strptime(report->>'procLaunch', '%Y-%m-%d %H:%M:%S.%f %z') AS process_started_at,
       try_strptime(report->>'captureTime', '%Y-%m-%d %H:%M:%S.%f %z') AS captured_at,
       report->'exception' AS exception,
       report->'termination' AS termination,
       report->'threads' AS threads, report->'usedImages' AS images
FROM documents;

CREATE OR REPLACE VIEW meta.server_exits AS
SELECT file, line_number, raw_line, event,
       event->>'instance_id' AS instance_id,
       try_cast(event->>'pid' AS BIGINT) AS pid,
       try_cast(event->>'exit_status' AS INTEGER) AS exit_status
FROM meta.server_events WHERE event->>'event' = 'exit';

CREATE OR REPLACE VIEW meta.server_incidents AS
SELECT e.*, c.file AS crash_file, c.captured_at, c.exception, c.termination
FROM meta.server_exits e LEFT JOIN meta.server_crashes c
  ON e.pid = c.pid
 AND abs(date_diff('second', try_cast(e.event->>'at' AS TIMESTAMPTZ),
                  c.captured_at)) <= 60
WHERE e.exit_status IS DISTINCT FROM 0;

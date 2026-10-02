-- Requires telemetry.sql and telemetry_export.sql. The rendered job has its own cursor; it
-- cannot advance production's quack_traces watermark.
INSERT INTO meta.otlp_export_cursor BY NAME
SELECT 'telemetry_export_test' AS export_name, now() AS completed_at,
       repeat('f', 64) AS source_key, now() AS advanced_at
ON CONFLICT DO UPDATE SET completed_at = excluded.completed_at,
                          source_key = excluded.source_key,
                          advanced_at = excluded.advanced_at;

CREATE TEMP TABLE telemetry_export_input AS
SELECT 'good' AS kind,
       http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'},
                 json_object('sql', 'SELECT 42 AS telemetry_export_good')) AS receipt
UNION ALL
SELECT 'error',
       http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'},
                 json_object('sql', 'SELECT telemetry_export_missing_column'));

SELECT CASE WHEN bool_and(receipt.status IN (200, 422))
            THEN 'native good and error requests completed' 
            ELSE error('test request failed before native Quack completion: ' || string_agg(receipt::VARCHAR, chr(10))) END AS result
FROM telemetry_export_input;

CREATE TEMP TABLE telemetry_export_first AS
SELECT http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'},
                 json_object('sql', replace(content, '''quack_traces''', '''telemetry_export_test'''))) AS receipt
FROM read_text('/Users/aloksubbarao/duckdb-skills/server/telemetry_export.sql');
SELECT CASE WHEN receipt.status = 200 THEN 'first bounded export completed'
            ELSE error('first export failed: ' || receipt::VARCHAR) END AS result
FROM telemetry_export_first;

CREATE TEMP TABLE telemetry_export_spans AS
SELECT trace_id, span_id, status_code, status_status_message, span_attributes
FROM otlp_events
WHERE signal = 'traces' AND scope_name = 'duckdb.quack.native'
  AND contains(span_attributes, 'telemetry_export_');

SELECT CASE WHEN EXISTS (FROM telemetry_export_spans
                         WHERE contains(span_attributes, 'telemetry_export_good')
                           AND status_code = 0
                           AND contains(json_extract_string(span_attributes::JSON, '$."db.statement"'),
                                        'SELECT 42 AS telemetry_export_good')
                           AND trace_id IS NOT NULL AND span_id IS NOT NULL)
            THEN 'successful native query is an OTLP span with real IDs'
            ELSE error('successful query span missing') END AS result
UNION ALL
SELECT CASE WHEN EXISTS (FROM telemetry_export_spans
                         WHERE contains(span_attributes, 'telemetry_export_missing_column')
                           AND status_code = 2
                           AND status_status_message IS NOT NULL)
            THEN 'native query error is an OTLP error span'
            ELSE error('error query span missing') END;

CREATE TEMP TABLE telemetry_export_before AS
SELECT * FROM telemetry_export_spans;
CREATE TEMP TABLE telemetry_export_attempts_before AS
SELECT * FROM meta.otlp_export_attempts WHERE export_name = 'telemetry_export_test';
CREATE TEMP TABLE telemetry_export_second AS
SELECT http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'},
                 json_object('sql', replace(content, '''quack_traces''', '''telemetry_export_test'''))) AS receipt
FROM read_text('/Users/aloksubbarao/duckdb-skills/server/telemetry_export.sql');
SELECT CASE WHEN receipt.status = 200 AND (receipt.body->>'$') = '[]' THEN 'no-op export has no eligible source rows'
            ELSE error('no-op export failed: ' || receipt::VARCHAR) END AS result
FROM telemetry_export_second;
CREATE TEMP TABLE telemetry_export_after AS
SELECT trace_id, span_id, status_code, status_status_message, span_attributes
FROM otlp_events
WHERE signal = 'traces' AND scope_name = 'duckdb.quack.native'
  AND contains(span_attributes, 'telemetry_export_');
CREATE TEMP TABLE telemetry_export_difference AS
(
SELECT * FROM telemetry_export_before EXCEPT ALL SELECT * FROM telemetry_export_after
)
UNION ALL BY NAME
(
SELECT * FROM telemetry_export_after EXCEPT ALL SELECT * FROM telemetry_export_before
);
CREATE TEMP TABLE telemetry_export_attempts_difference AS
(
SELECT * FROM telemetry_export_attempts_before
EXCEPT ALL
SELECT * FROM meta.otlp_export_attempts WHERE export_name = 'telemetry_export_test'
)
UNION ALL BY NAME
(
SELECT * FROM meta.otlp_export_attempts WHERE export_name = 'telemetry_export_test'
EXCEPT ALL
SELECT * FROM telemetry_export_attempts_before
);
SELECT CASE WHEN NOT EXISTS (FROM telemetry_export_difference)
                  AND NOT EXISTS (FROM telemetry_export_attempts_difference)
            THEN 'cursor prevents duplicate spans on no-op export'
            ELSE error('no-op export duplicated an OTLP span') END AS result;

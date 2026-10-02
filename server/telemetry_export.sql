-- Bounded bridge from native Quack completion records to the existing OTLP/HTTP intake.
-- Native logs remain authoritative; this cursor and receipt ledger only prove export delivery.
CREATE SCHEMA IF NOT EXISTS meta;
CREATE TABLE IF NOT EXISTS meta.otlp_export_cursor (
  export_name VARCHAR PRIMARY KEY,
  completed_at TIMESTAMPTZ NOT NULL,
  source_key VARCHAR NOT NULL,
  advanced_at TIMESTAMPTZ NOT NULL
);
INSERT INTO meta.otlp_export_cursor BY NAME
SELECT 'quack_traces' AS export_name, TIMESTAMPTZ '-infinity' AS completed_at,
       '' AS source_key, now() AS advanced_at
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS meta.otlp_export_attempts (
  attempted_at TIMESTAMPTZ NOT NULL,
  export_name VARCHAR NOT NULL,
  source_count UBIGINT NOT NULL,
  source_keys VARCHAR[] NOT NULL,
  request_payload JSON NOT NULL,
  receipt JSON NOT NULL,
  accepted BOOLEAN NOT NULL
);

CREATE OR REPLACE VIEW meta.otlp_quack_trace_source AS
WITH native_quack AS (
  SELECT l.*, parse_duckdb_log_message('Quack', l.message) AS quack
  FROM meta.native_logs l
  WHERE l.type = 'Quack'
), completed AS (
  SELECT n.filename, n.timestamp AS completed_at, n.message AS raw_message,
         n.quack.quack_connection_id, n.quack.client_query_id, n.quack.query,
         n.quack.duration_ms, n.quack.response_type, n.quack.error,
         sha256(concat_ws(chr(31), n.filename, n.timestamp::VARCHAR,
                          coalesce(n.quack.quack_connection_id, ''),
                          coalesce(n.quack.client_query_id::VARCHAR, ''), n.message)) AS source_key
  FROM native_quack n
  WHERE n.quack.message_type = 'PREPARE_REQUEST'
    AND n.quack.server IS NULL
    AND n.quack.query IS NOT NULL
    AND NOT contains(n.quack.query, 'meta.otlp_export')
)
SELECT c.*, coalesce(i.instance_id, 'legacy') AS server_instance_id,
       left(source_key, 32) AS trace_id,
       left(sha256('span' || source_key), 16) AS span_id
FROM completed c
LEFT JOIN meta.server_instances i ON c.filename = i.native_log_path;

CREATE OR REPLACE TEMP TABLE _otlp_export_batch AS
SELECT s.*
FROM meta.otlp_quack_trace_source s
INNER JOIN meta.otlp_export_cursor c ON c.export_name = 'quack_traces'
WHERE (s.completed_at, s.source_key) > (c.completed_at, c.source_key)
ORDER BY s.completed_at, s.source_key
LIMIT 200;

CREATE OR REPLACE TEMP TABLE _otlp_export_end AS
SELECT completed_at, source_key FROM _otlp_export_batch
QUALIFY row_number() OVER (ORDER BY completed_at DESC, source_key DESC) = 1;

CREATE OR REPLACE TEMP TABLE _otlp_export_payload AS
SELECT len(list(source_key)) AS source_count,
       list(source_key ORDER BY completed_at, source_key) AS source_keys,
       json_object('resourceSpans', list(
         json_object('resource', json_object('attributes', [
           json_object('key', 'service.name', 'value', json_object('stringValue', 'duckdb.quack')),
           json_object('key', 'service.instance.id', 'value', json_object('stringValue', server_instance_id)),
           json_object('key', 'duckdb.native_log.filename', 'value', json_object('stringValue', filename))
         ]), 'scopeSpans', [json_object('scope', json_object('name', 'duckdb.quack.native'),
           'spans', [json_object(
             'traceId', trace_id, 'spanId', span_id, 'name', 'duckdb.quack.query', 'kind', 1,
             'startTimeUnixNano', (epoch_ns(completed_at) - duration_ms * 1000000)::VARCHAR,
             'endTimeUnixNano', epoch_ns(completed_at)::VARCHAR,
             'status', json_object('code', CASE WHEN error IS NULL THEN 0 ELSE 2 END,
                                   'message', coalesce(error, '')),
             'attributes', [
               json_object('key', 'db.statement', 'value', json_object('stringValue', query)),
               json_object('key', 'duckdb.quack.duration_ms', 'value', json_object('intValue', duration_ms::VARCHAR)),
               json_object('key', 'duckdb.quack.response_type', 'value', json_object('stringValue', response_type)),
               json_object('key', 'duckdb.quack.error', 'value', json_object('stringValue', coalesce(error, ''))),
               json_object('key', 'duckdb.quack.connection_id', 'value', json_object('stringValue', coalesce(quack_connection_id, ''))),
               json_object('key', 'duckdb.quack.client_query_id', 'value', json_object('stringValue', coalesce(client_query_id::VARCHAR, ''))),
               json_object('key', 'duckdb.native_log.source_key', 'value', json_object('stringValue', source_key)),
               json_object('key', 'duckdb.native_log.message', 'value', json_object('stringValue', raw_message))
             ]
           )]
         )]
       )
       ORDER BY completed_at, source_key
       )) AS payload
FROM _otlp_export_batch;

CREATE OR REPLACE TEMP TABLE _otlp_export_raw_delivery AS
SELECT p.*, http_post('http://127.0.0.1:9495/v1/traces',
                       MAP {'Content-Type': 'application/json'}, p.payload::VARCHAR) AS receipt
FROM _otlp_export_payload p
WHERE source_count > 0;

CREATE OR REPLACE TEMP TABLE _otlp_export_delivery AS
SELECT *, receipt.status IS NOT DISTINCT FROM 200
              AND (receipt.body->>'$') IS NOT DISTINCT FROM '[{"Count":1}]' AS accepted
FROM _otlp_export_raw_delivery;

INSERT INTO meta.otlp_export_attempts BY NAME
SELECT now() AS attempted_at, 'quack_traces' AS export_name, source_count, source_keys,
       payload AS request_payload, to_json(receipt) AS receipt, accepted
FROM _otlp_export_delivery;

SELECT error('OTLP trace export failed: ' || receipt::VARCHAR)
FROM _otlp_export_delivery WHERE accepted IS DISTINCT FROM true;

UPDATE meta.otlp_export_cursor c
SET completed_at = e.completed_at, source_key = e.source_key, advanced_at = now()
FROM _otlp_export_end e
WHERE c.export_name = 'quack_traces'
  AND EXISTS (FROM _otlp_export_delivery d WHERE d.accepted IS NOT DISTINCT FROM true);

SELECT source_count, source_keys, accepted, receipt
FROM _otlp_export_delivery;

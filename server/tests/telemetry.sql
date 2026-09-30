-- Execute after quackapi.sql and telemetry.sql on the selected dev Quack service.
-- These are real OTLP/HTTP request bodies: each route keeps its raw JSON file and the native
-- OTLP readers below must expose the typed row and its attributes.
CREATE TEMP TABLE telemetry_payloads AS
SELECT '/v1/logs' AS path,
$$ {"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"telemetry-sql-regression"}}]},"scopeLogs":[{"scope":{"name":"telemetry.sql"},"logRecords":[{"timeUnixNano":"1727654400000000000","severityNumber":9,"severityText":"INFO","body":{"stringValue":"telemetry-log-body"},"attributes":[{"key":"test.case","value":{"stringValue":"log"}}]}]}]}]} $$ AS payload
UNION ALL
SELECT '/v1/traces',
$$ {"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"telemetry-sql-regression"}}]},"scopeSpans":[{"scope":{"name":"telemetry.sql"},"spans":[{"traceId":"0123456789abcdef0123456789abcdef","spanId":"0123456789abcdef","name":"telemetry-trace","kind":1,"startTimeUnixNano":"1727654400000000000","endTimeUnixNano":"1727654401000000000","attributes":[{"key":"test.case","value":{"stringValue":"trace"}}]}]}]}]} $$
UNION ALL
SELECT '/v1/metrics',
$$ {"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"telemetry-sql-regression"}}]},"scopeMetrics":[{"scope":{"name":"telemetry.sql"},"metrics":[{"name":"telemetry.sum","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"attributes":[{"key":"test.case","value":{"stringValue":"sum"}}],"startTimeUnixNano":"1727654400000000000","timeUnixNano":"1727654401000000000","asInt":"7"}]}},{"name":"telemetry.gauge","gauge":{"dataPoints":[{"attributes":[{"key":"test.case","value":{"stringValue":"gauge"}}],"timeUnixNano":"1727654401000000000","asDouble":3.5}]}},{"name":"telemetry.histogram","histogram":{"aggregationTemporality":2,"dataPoints":[{"attributes":[{"key":"test.case","value":{"stringValue":"histogram"}}],"startTimeUnixNano":"1727654400000000000","timeUnixNano":"1727654401000000000","count":"2","sum":3.0,"bucketCounts":["1","1"],"explicitBounds":[2.0],"min":1.0,"max":2.0}]}},{"name":"telemetry.exp_histogram","exponentialHistogram":{"aggregationTemporality":2,"dataPoints":[{"attributes":[{"key":"test.case","value":{"stringValue":"exp_histogram"}}],"startTimeUnixNano":"1727654400000000000","timeUnixNano":"1727654401000000000","count":"2","sum":3.0,"scale":0,"zeroCount":"0","positive":{"offset":0,"bucketCounts":["2"]},"min":1.0,"max":2.0}]}}]}]}]} $$;

CREATE TEMP TABLE telemetry_receipts AS
SELECT path,
       http_post('http://127.0.0.1:9495' || path,
                 MAP {'Content-Type': 'application/json'}, payload) AS receipt
FROM telemetry_payloads;

SELECT CASE WHEN bool_and(receipt.status = 200) THEN 'OTLP ingest routes accepted every signal'
            ELSE error('OTLP ingest route rejected a real payload: ' || string_agg(receipt::VARCHAR, chr(10))) END AS result
FROM telemetry_receipts;

CREATE TEMP TABLE telemetry_rows_before AS
SELECT * FROM otlp_events WHERE service_name = 'telemetry-sql-regression';
CREATE TEMP TABLE telemetry_reload AS
SELECT http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'},
                 json_object('sql', content)) AS receipt
FROM read_text('/Users/aloksubbarao/duckdb-skills/server/telemetry.sql');
SELECT CASE WHEN receipt.status = 200 THEN 'unified view reload succeeded'
            ELSE error('unified view reload failed: ' || receipt::VARCHAR) END AS result
FROM telemetry_reload;

CREATE TEMP TABLE telemetry_rows_after AS
SELECT * FROM otlp_events WHERE service_name = 'telemetry-sql-regression';
CREATE TEMP TABLE telemetry_reload_difference AS
SELECT * FROM telemetry_rows_before
EXCEPT ALL
SELECT * FROM telemetry_rows_after
UNION ALL BY NAME
SELECT * FROM telemetry_rows_after
EXCEPT ALL
SELECT * FROM telemetry_rows_before;

SELECT CASE WHEN NOT EXISTS (FROM telemetry_reload_difference)
            THEN 'view reload is a no-op for retained raw OTLP events'
            ELSE error('view reload changed retained OTLP rows') END AS result;

SELECT CASE WHEN EXISTS (FROM otlp_events
                         WHERE signal = 'logs' AND metric_kind IS NULL
                           AND service_name = 'telemetry-sql-regression'
                           AND body = 'telemetry-log-body'
                           AND log_attributes = '{"test.case":"log"}')
            THEN 'logs retain body and attributes' ELSE error('missing typed OTLP log') END AS result
UNION ALL
SELECT CASE WHEN EXISTS (FROM otlp_events
                         WHERE signal = 'traces' AND metric_kind IS NULL
                           AND trace_id = '0123456789abcdef0123456789abcdef'
                           AND span_id = '0123456789abcdef'
                           AND name = 'telemetry-trace'
                           AND span_attributes = '{"test.case":"trace"}')
            THEN 'traces retain correlation identifiers and attributes' ELSE error('missing typed OTLP trace') END
UNION ALL
SELECT CASE WHEN EXISTS (FROM otlp_events
                         WHERE signal = 'metrics' AND metric_kind = 'sum'
                           AND name = 'telemetry.sum' AND int_value = 7
                           AND metric_attributes = '{"test.case":"sum"}')
            THEN 'sum metrics retain value and attributes' ELSE error('missing typed OTLP sum') END
UNION ALL
SELECT CASE WHEN EXISTS (FROM otlp_events
                         WHERE signal = 'metrics' AND metric_kind = 'gauge'
                           AND name = 'telemetry.gauge' AND double_value = 3.5
                           AND metric_attributes = '{"test.case":"gauge"}')
            THEN 'gauge metrics retain value and attributes' ELSE error('missing typed OTLP gauge') END
UNION ALL
SELECT CASE WHEN EXISTS (FROM otlp_events
                         WHERE signal = 'metrics' AND metric_kind = 'histogram'
                           AND name = 'telemetry.histogram' AND count = 2 AND sum = 3.0
                           AND bucket_counts = [1, 1] AND explicit_bounds = [2.0]
                           AND metric_attributes = '{"test.case":"histogram"}')
            THEN 'histograms retain buckets and attributes' ELSE error('missing typed OTLP histogram') END
UNION ALL
SELECT CASE WHEN EXISTS (FROM otlp_events
                         WHERE signal = 'metrics' AND metric_kind = 'exp_histogram'
                           AND name = 'telemetry.exp_histogram' AND count = 2 AND sum = 3.0
                           AND positive_bucket_counts = [2]
                           AND metric_attributes = '{"test.case":"exp_histogram"}')
            THEN 'exponential histograms retain buckets and attributes' ELSE error('missing typed OTLP exponential histogram') END;

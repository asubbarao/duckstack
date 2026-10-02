-- One native, lossless OTLP surface. The QuackAPI routes retain each request body under
-- otlp_dir; these readers are the extension's typed projection of those raw files.
CREATE OR REPLACE VIEW otlp_events AS
SELECT 'logs'::VARCHAR AS signal, NULL::VARCHAR AS metric_kind, *
FROM read_otlp_logs(getenv('HOME') || '/.duck/otlp/signal=logs/*.json')
UNION ALL BY NAME
SELECT 'traces'::VARCHAR AS signal, NULL::VARCHAR AS metric_kind, *
FROM read_otlp_traces(getenv('HOME') || '/.duck/otlp/signal=traces/*.json')
UNION ALL BY NAME
SELECT 'metrics'::VARCHAR AS signal, 'sum'::VARCHAR AS metric_kind, *
FROM read_otlp_metrics_sum(getenv('HOME') || '/.duck/otlp/signal=metrics/*.json')
UNION ALL BY NAME
SELECT 'metrics'::VARCHAR AS signal, 'gauge'::VARCHAR AS metric_kind, *
FROM read_otlp_metrics_gauge(getenv('HOME') || '/.duck/otlp/signal=metrics/*.json')
UNION ALL BY NAME
SELECT 'metrics'::VARCHAR AS signal, 'histogram'::VARCHAR AS metric_kind, *
FROM read_otlp_metrics_histogram(getenv('HOME') || '/.duck/otlp/signal=metrics/*.json')
UNION ALL BY NAME
SELECT 'metrics'::VARCHAR AS signal, 'exp_histogram'::VARCHAR AS metric_kind, *
FROM read_otlp_metrics_exp_histogram(getenv('HOME') || '/.duck/otlp/signal=metrics/*.json');

-- These former entry points held no data; callers filter the broad view instead.
DROP VIEW IF EXISTS otlp_logs;
DROP VIEW IF EXISTS otlp_traces;
DROP VIEW IF EXISTS otlp_metrics_sum;
DROP VIEW IF EXISTS otlp_metrics_gauge;
DROP VIEW IF EXISTS otlp_metrics_histogram;
DROP VIEW IF EXISTS otlp_metrics_exp_histogram;

-- Raw source coverage is the only scheduled stream work while cron is serial.
CREATE SCHEMA IF NOT EXISTS agent;
CREATE TABLE IF NOT EXISTS agent.stream_refresh (
    run_id UUID PRIMARY KEY,
    instance_id VARCHAR,
    started_at TIMESTAMPTZ NOT NULL,
    source_coverage_at TIMESTAMPTZ NOT NULL,
    completed_at TIMESTAMPTZ,
    status VARCHAR NOT NULL,
    error VARCHAR,
    source_updated_through TIMESTAMPTZ,
    source_rows BIGINT,
    normalized_rows BIGINT,
    mutated_rows BIGINT,
    stream_rows BIGINT
);
ALTER TABLE agent.stream_refresh ADD COLUMN IF NOT EXISTS mutated_rows BIGINT;

CREATE OR REPLACE TEMP TABLE stream_jobs AS
SELECT '-- Refresh agent.stream raw.' || chr(10) ||
    string_agg(content, chr(10) ORDER BY filename) AS query,
    '0 */5 * * * *' AS schedule
FROM read_text([
    '/Users/aloksubbarao/duckdb-skills/server/agent_base.sql',
    '/Users/aloksubbarao/duckdb-skills/server/agent_stream_incremental.sql',
    '/Users/aloksubbarao/duckdb-skills/server/agent_stream_views.sql'
]);

SELECT cron_delete(job_id)
FROM cron_jobs()
WHERE starts_with(query, '-- Refresh every five minutes.');

SELECT cron_delete(job_id)
FROM cron_jobs()
WHERE starts_with(query, '-- Refresh agent.stream search.');

SELECT cron_delete(job_id)
FROM cron_jobs()
WHERE starts_with(query, '-- Refresh agent.stream raw.');

-- Register before catch-up so a reader failure cannot leave refresh unscheduled.
SELECT cron(s.query, s.schedule)
FROM stream_jobs AS s
ANTI JOIN cron_jobs() AS j ON trim(j.query) = trim(s.query) AND j.schedule = s.schedule;

-- Startup catches missed source coverage, except while a fresh raw attempt is already running.
CREATE OR REPLACE TEMP TABLE stream_bootstrap AS
SELECT query
FROM stream_jobs
WHERE NOT EXISTS (
    SELECT run_id
    FROM agent.stream_refresh
    WHERE status = 'running' AND started_at >= now() - INTERVAL '10 minutes'
);
SET VARIABLE stream_bootstrap_query = (
    SELECT coalesce(max(query), 'SELECT ''agent.stream bootstrap skipped'' AS status')
    FROM stream_bootstrap
);
FROM quack_query('quack:localhost:9494', getvariable('stream_bootstrap_query'),
    token := getenv('QUACK_TOKEN'));

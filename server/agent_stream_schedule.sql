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
    '0 * * * * *' AS schedule
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

-- Cron is serial: a one-minute tick leaves room for the changed-session read.
SELECT cron(s.query, s.schedule)
FROM stream_jobs AS s
ANTI JOIN cron_jobs() AS j ON trim(j.query) = trim(s.query) AND j.schedule = s.schedule;

-- The first one-minute cron tick catches up after restart. A separate bootstrap
-- races that tick during a full snapshot and can leave both refreshes unfinished.

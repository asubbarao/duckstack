-- Two scheduled stream jobs while cron is serial: raw source coverage each minute, hour search every five.
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
])
UNION ALL
-- Hour search rows, then BM25 (only when changed) and up to 128 embeddings: about 3-8 s per tick.
SELECT '-- Refresh agent.stream hour search.' || chr(10) ||
    string_agg(content, chr(10) ORDER BY filename) AS query,
    '15 */5 * * * *' AS schedule
FROM read_text([
    '/Users/aloksubbarao/duckdb-skills/server/agent_stream_hour.sql',
    '/Users/aloksubbarao/duckdb-skills/server/agent_stream_hour_index.sql'
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

SELECT cron_delete(job_id)
FROM cron_jobs()
WHERE starts_with(query, '-- Refresh agent.stream hour search.');

-- Cron is serial: a one-minute tick leaves room for the changed-session read.
-- One job per statement: given several rows here, cron() registered every job with the first row's schedule.
SELECT cron(s.query, s.schedule)
FROM stream_jobs AS s
ANTI JOIN cron_jobs() AS j ON trim(j.query) = trim(s.query) AND j.schedule = s.schedule
WHERE starts_with(s.query, '-- Refresh agent.stream raw.');

SELECT cron(s.query, s.schedule)
FROM stream_jobs AS s
ANTI JOIN cron_jobs() AS j ON trim(j.query) = trim(s.query) AND j.schedule = s.schedule
WHERE starts_with(s.query, '-- Refresh agent.stream hour search.');

-- The first one-minute cron tick catches up after restart. A separate bootstrap
-- races that tick during a full snapshot and can leave both refreshes unfinished.

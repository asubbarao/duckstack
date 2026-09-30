-- pull.sql: one tick of the replica pull. setup.sql's cron posts this file's current text to /sql every 10 s, and
-- cronjob runs a job serially, so ticks never overlap. Each tick re-copies up to 4 due tables, most overdue first: a
-- table is due 5 minutes after its last ok copy, 30 s after a failed one, at once if never copied. So every table is
-- fully re-copied about every 5 minutes with at most 4 in flight (one unbounded fan-out of 133 overran the quack door:
-- 110 posts failed). Four concurrent posts stay within this replica's 4 DuckDB workers. The pending set is derived
-- from pull_log, never tracked; a failure is a row the next tick retries.
-- CREATE OR REPLACE swaps a table in one transaction; a reader sees the previous copy until the new one commits.
-- READ_ONLY: the replica never writes to its source. IF NOT EXISTS: a source that was down is attached next tick.
-- Two sources: the staging clone lands in schema public, the fake business profiles (bp_fake) in schema bp_fake.
ATTACH IF NOT EXISTS 'host=/tmp port=5432 user=aloksubbarao dbname=staging_extensions_20260929' AS pg (TYPE postgres, READ_ONLY);
ATTACH IF NOT EXISTS 'host=/tmp port=5432 user=aloksubbarao dbname=bp_fake' AS bp (TYPE postgres, READ_ONLY);
CREATE SCHEMA IF NOT EXISTS bp_fake;
-- The attach caches the source catalog; clearing it lets a table or column added upstream arrive.
CALL pg_clear_cache();

-- Rows -> statements -> quackapi_post to this process's /sql -> array_agg -> UNNEST -> pull_log.
-- Each body records its start in a temp table (connection-local), copies, then returns start, finish and rows.
-- quackapi_post(url, body JSON) -> STRUCT(status, reason, body, headers, error, reused_connection); unlike
-- http_client's http_post (status -1 at 10 s) it waits out a long copy (audit_log: ~2 s warm, 20-29 s from a cold
-- Postgres cache).
INSERT INTO pull_log BY NAME
WITH source AS (
    -- Base tables from the source's own catalog; the attach's duckdb_tables() also lists its 6 views.
    -- pull_log's table_name is schema-qualified (public.x, bp_fake.x) so the two sources never collide.
    SELECT 'pg' AS src, 'public' AS target, table_name, 'public.' || table_name AS key
    FROM postgres_query('pg', $$SELECT table_name::text AS table_name FROM information_schema.tables
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE'$$)
    UNION ALL
    SELECT 'bp', 'bp_fake', table_name, 'bp_fake.' || table_name
    FROM postgres_query('bp', $$SELECT table_name::text AS table_name FROM information_schema.tables
        WHERE table_schema = 'public' AND table_type = 'BASE TABLE'$$)
), last_attempt AS (
    SELECT table_name AS key,
        run_started + CASE WHEN status = 'ok' THEN INTERVAL 5 MINUTE ELSE INTERVAL 30 SECOND END AS due_at
    FROM pull_log
    QUALIFY row_number() OVER (PARTITION BY table_name ORDER BY run_started DESC) = 1
), due AS (
    SELECT s.key AS table_name, now() AS run_started, strftime(now(), '%Y%m%dT%H%M%SZ') AS run_id,
        s.target || '.' || chr(34) || s.table_name || chr(34) AS ident,
        s.src || '.public.' || chr(34) || s.table_name || chr(34) AS origin, chr(39) || s.key || chr(39) AS lit,
        chr(34) || '_pull_' || s.target || '_' || s.table_name || chr(34) AS mark
    FROM source s LEFT JOIN last_attempt l USING (key)
    WHERE coalesce(l.due_at, '-infinity'::TIMESTAMPTZ) <= now()
    ORDER BY l.due_at NULLS FIRST, s.key
    LIMIT 4
), statements AS (
    SELECT table_name, run_started, run_id, array_to_string([
        'CREATE OR REPLACE TEMP TABLE ' || mark || ' AS SELECT ' || lit || ' AS table_name, now() AS started',
        'CREATE OR REPLACE TABLE ' || ident || ' AS FROM ' || origin,
        'SELECT m.started, now() AS finished, n.rows FROM ' || mark || ' m JOIN (SELECT ' || lit
            || ' AS table_name, coalesce(len(array_agg(true)), 0) AS rows FROM ' || ident || ') n USING (table_name)',
        'DROP TABLE ' || mark], ';' || chr(10)) AS statement
    FROM due
), posted AS (
    SELECT array_agg({table_name: table_name, run_started: run_started, run_id: run_id, statement: statement,
        receipt: quackapi_post('http://127.0.0.1:9511/sql', json_object('sql', statement))}) AS receipts
    FROM statements
), landed AS (
    SELECT unnest(r), r.receipt.status AS http_status,
        from_json(CASE WHEN http_status = 200 THEN r.receipt.body END,
            '[{"started": "TIMESTAMPTZ", "finished": "TIMESTAMPTZ", "rows": "BIGINT"}]')[1] AS result
    FROM posted CROSS JOIN UNNEST(receipts) AS u(r)
)
SELECT run_id, run_started, table_name, result.rows AS rows, result.started AS started, result.finished AS finished,
    CASE WHEN result.rows IS NOT NULL THEN 'ok' ELSE 'error' END AS status, http_status,
    CASE WHEN result.rows IS NULL THEN coalesce(receipt.error, receipt.body) END AS error,
    receipt.headers['X-Request-ID'] AS request_id, statement, receipt.body AS receipt_body
FROM landed;

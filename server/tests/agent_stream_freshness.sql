-- Regression: a current session update must replace old, backdated stream rows idempotently.
CREATE SCHEMA IF NOT EXISTS agent_stream_freshness_test;
CREATE OR REPLACE TABLE agent_stream_freshness_test.stream AS
SELECT 'codex' AS system, 'session-a' AS session_id, 'obsolete-id' AS id,
       TIMESTAMPTZ '2026-09-28 18:00:00+00' AS ts, 'old' AS message_content;
CREATE OR REPLACE TABLE agent_stream_freshness_test.reader AS
SELECT 'codex' AS system, 'session-a' AS session_id, 'preserved-old-id' AS id,
       TIMESTAMPTZ '2026-09-28 17:00:00+00' AS ts, 'older member' AS message_content,
       NULL::TIMESTAMPTZ AS session_updated_at
UNION ALL
SELECT 'codex', 'session-a', 'new-id',
       TIMESTAMPTZ '2026-09-28 18:00:00+00' AS ts, 'corrected backfill' AS message_content,
       TIMESTAMPTZ '2026-09-28 21:30:00+00' AS session_updated_at;
CREATE OR REPLACE TABLE agent_stream_freshness_test.changed_sessions AS
SELECT DISTINCT system, session_id
FROM agent_stream_freshness_test.reader
WHERE greatest(session_updated_at, ts) >= TIMESTAMPTZ '2026-09-28 21:00:00+00';
CREATE OR REPLACE TABLE agent_stream_freshness_test.source AS
SELECT r.*
FROM agent_stream_freshness_test.reader AS r
SEMI JOIN agent_stream_freshness_test.changed_sessions AS c USING (system, session_id);

CREATE OR REPLACE TABLE agent_stream_freshness_test.reconciled AS
SELECT s.*
FROM agent_stream_freshness_test.stream AS s
ANTI JOIN (SELECT DISTINCT system, session_id FROM agent_stream_freshness_test.source) AS r USING (system, session_id)
UNION ALL BY NAME
SELECT * EXCLUDE (session_updated_at) FROM agent_stream_freshness_test.source;

CREATE OR REPLACE TABLE agent_stream_freshness_test.rerun AS
SELECT * FROM agent_stream_freshness_test.reconciled;
CREATE OR REPLACE TABLE agent_stream_freshness_test.tombstones AS
SELECT * FROM agent_stream_freshness_test.reconciled
EXCEPT ALL
SELECT * FROM agent_stream_freshness_test.rerun;
CREATE OR REPLACE TABLE agent_stream_freshness_test.upserts AS
SELECT * FROM agent_stream_freshness_test.rerun
EXCEPT ALL
SELECT * FROM agent_stream_freshness_test.reconciled;
CREATE OR REPLACE TABLE agent_stream_freshness_test.mutation_ids AS
SELECT id FROM agent_stream_freshness_test.tombstones
UNION ALL
SELECT id FROM agent_stream_freshness_test.upserts;

CREATE OR REPLACE TEMP TABLE agent_stream_freshness_checks AS
SELECT CASE WHEN count(id) = 0
            THEN 'pass: timestamp-only overlap misses this backfill'
            ELSE error('fixture no longer proves the old cutoff failure') END AS verification
FROM agent_stream_freshness_test.source
WHERE ts >= TIMESTAMPTZ '2026-09-28 21:00:00+00'
UNION ALL
SELECT CASE WHEN count(id) = 2
                  AND count(id) FILTER (WHERE id = 'new-id' AND message_content = 'corrected backfill') = 1
                  AND count(id) FILTER (WHERE id = 'preserved-old-id' AND message_content = 'older member') = 1
            THEN 'pass: changed session includes its older member and replaces stale rows'
            ELSE error('freshness reconciliation failed') END
FROM agent_stream_freshness_test.reconciled
UNION ALL
SELECT CASE WHEN count(id) = 2
                  AND count(DISTINCT id) = 2
            THEN 'pass: no-op rerun preserves all corrected rows'
            ELSE error('freshness idempotence failed') END
FROM agent_stream_freshness_test.rerun
UNION ALL
SELECT CASE WHEN count(id) = 0
            THEN 'pass: no-op produces no delete or insert ids'
            ELSE error('no-op would mutate stream rows') END
FROM agent_stream_freshness_test.mutation_ids;
DROP SCHEMA agent_stream_freshness_test CASCADE;
SELECT * FROM agent_stream_freshness_checks;

-- agent.stream_hour: one search row per (system, session_id, UTC hour). Full text stays in agent.stream
-- (stream_message(id)); this table keeps ordered ids and speaker-prefixed head/tail items of at most 205 chars.
-- Incremental: an hour is rebuilt only when its fingerprint (messages, last ts, chars) changes, so closed hours
-- stay put, the open hour and any late-arriving rows are refreshed, and vanished hours are deleted.
CREATE SCHEMA IF NOT EXISTS agent;
CREATE TABLE IF NOT EXISTS agent.stream_hour (
    hour_id VARCHAR PRIMARY KEY, system VARCHAR, session_id VARCHAR, hour TIMESTAMPTZ, project_path VARCHAR,
    first_ts TIMESTAMPTZ, last_ts TIMESTAMPTZ, message_count BIGINT, source_chars BIGINT,
    role_counts MAP(VARCHAR, UBIGINT), ids VARCHAR[], condensed_items VARCHAR[], search_text VARCHAR,
    built_at TIMESTAMPTZ
);

-- Rows without text (about 60% of agent.stream) carry nothing to search. Drop typed human pastes over 10,000
-- chars and non-human rows under 50 chars (fixed tool-call stubs); short human rows are kept.
CREATE OR REPLACE TEMP TABLE stream_hour_rows AS
WITH classified AS (
    SELECT s.id, s.system, s.session_id, s.ts, s.project_path, s.message_role, s.message_content, s.content_length,
        date_trunc('hour', s.ts) AS hour, coalesce(u.speaker, s.message_role) AS speaker,
        coalesce(u.user_kind = 'typed', false) AS is_typed,
        coalesce(u.speaker = 'human' AND u.user_text IS NOT NULL, false) AS is_human
    FROM agent.stream AS s
    LEFT JOIN agent.user_text AS u USING (id)
    WHERE s.message_content IS NOT NULL AND s.ts IS NOT NULL
)
SELECT id, system, session_id, ts, project_path, message_role, content_length, hour,
    md5(concat_ws(chr(31), system, session_id, hour::VARCHAR)) AS hour_id,
    speaker || ': ' || CASE WHEN content_length <= 200 THEN message_content
        ELSE left(message_content, 100) || ' ... ' || right(message_content, 100) END AS condensed
FROM classified
WHERE NOT (is_typed AND content_length > 10000)
  AND NOT (content_length < 50 AND NOT is_human);

CREATE OR REPLACE TEMP TABLE stream_hour_fingerprint AS
SELECT hour_id, count(id) AS message_count, max(ts) AS last_ts, sum(content_length) AS source_chars
FROM stream_hour_rows
GROUP BY hour_id;

CREATE OR REPLACE TEMP TABLE stream_hour_changed AS
SELECT f.hour_id FROM stream_hour_fingerprint AS f
ANTI JOIN agent.stream_hour AS h USING (hour_id, message_count, last_ts, source_chars)
UNION ALL
SELECT h.hour_id FROM agent.stream_hour AS h
ANTI JOIN stream_hour_fingerprint AS f USING (hour_id);

DELETE FROM agent.stream_hour AS h USING stream_hour_changed AS c WHERE h.hour_id = c.hour_id;

INSERT INTO agent.stream_hour BY NAME
SELECT r.hour_id, r.system, r.session_id, r.hour,
    arg_max(r.project_path, r.ts) FILTER (r.project_path IS NOT NULL) AS project_path,
    min(r.ts) AS first_ts, max(r.ts) AS last_ts, count(r.id) AS message_count,
    sum(r.content_length) AS source_chars, histogram(r.message_role) AS role_counts,
    array_agg(r.id ORDER BY r.ts, r.id) AS ids,
    array_agg(r.condensed ORDER BY r.ts, r.id) AS condensed_items,
    array_to_string(array_agg(r.condensed ORDER BY r.ts, r.id), chr(10)) AS search_text,
    now() AS built_at
FROM stream_hour_rows AS r
SEMI JOIN stream_hour_changed AS c USING (hour_id)
GROUP BY r.hour_id, r.system, r.session_id, r.hour;

SELECT count(c.hour_id) AS rebuilt_hours FROM stream_hour_changed AS c;

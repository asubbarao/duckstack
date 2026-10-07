-- Search indexes for agent.stream_hour; runs right after agent_stream_hour.sql in the same cron job.
-- BM25: the native fts index is rebuilt (about 7 s) only when the hour table changed since the last build.
-- Vectors: 384-d quackformers embeddings, newest hours first, at most 128 per tick (warm model: about 5 s).
LOAD quackformers;
CREATE TABLE IF NOT EXISTS agent.stream_hour_fts_build (
    built_at TIMESTAMPTZ, fts_schema VARCHAR, fingerprint HUGEINT, hours BIGINT, status INTEGER, body VARCHAR
);
CREATE TABLE IF NOT EXISTS agent.stream_hour_vector (
    hour_id VARCHAR PRIMARY KEY, content_hash VARCHAR, model_extension VARCHAR, model_version VARCHAR,
    embedding FLOAT[384], embedded_at TIMESTAMPTZ
);

-- A build counts only while its fts schema still exists. A PRAGMA cannot be conditional, so it is self-dispatched;
-- /sql re-serializes statements and drops PRAGMA named arguments (overwrite), so the PRAGMA travels as a string
-- literal inside quack_query. The overwrite is transactional: searches keep the old index until it commits.
CREATE OR REPLACE TEMP TABLE stream_hour_fts_due AS
WITH hours AS (
    SELECT 'fts_agent_stream_hour' AS fts_schema, sum(hash(hour_id, built_at))::HUGEINT AS fingerprint,
        count(hour_id) AS hours
    FROM agent.stream_hour
), built AS (
    SELECT b.fts_schema, b.fingerprint
    FROM agent.stream_hour_fts_build AS b
    JOIN duckdb_tables() AS t ON t.schema_name = b.fts_schema AND t.table_name = 'docs'
    WHERE b.status = 200
)
SELECT h.* FROM hours AS h
ANTI JOIN built AS b ON b.fts_schema = h.fts_schema AND b.fingerprint = h.fingerprint
WHERE h.hours > 0;

INSERT INTO agent.stream_hour_fts_build BY NAME
WITH sent AS (
    SELECT d.*, http_post('http://localhost:9495/sql', MAP {'Content-Type': 'application/json'},
        {'sql': $q$FROM quack_query('quack:localhost:9494', $p$PRAGMA create_fts_index('agent.stream_hour', 'hour_id',
            'search_text', stemmer = 'porter', stopwords = 'english', lower = 1, strip_accents = 1, overwrite = 1)$p$,
            token := getenv('QUACK_TOKEN'))$q$}::JSON) AS receipt
    FROM stream_hour_fts_due AS d
)
SELECT now() AS built_at, fts_schema, fingerprint, hours, receipt.status AS status, left(receipt.body, 500) AS body
FROM sent;

DELETE FROM agent.stream_hour_vector WHERE hour_id NOT IN (SELECT hour_id FROM agent.stream_hour);

-- Embed the conversation (human and agent items); a tool-only hour falls back to its whole search text.
-- The model reads about the first 2,000 characters.
INSERT OR REPLACE INTO agent.stream_hour_vector BY NAME
WITH texts AS (
    SELECT hour_id, hour, 'quackformers' AS model_extension,
        array_to_string(list_filter(condensed_items, x -> split_part(x, ':', 1) IN ('human', 'agent')), chr(10)) AS dialog,
        left(CASE WHEN dialog = '' THEN search_text ELSE dialog END, 2000) AS embed_text
    FROM agent.stream_hour
), keyed AS (
    SELECT t.hour_id, t.hour, t.embed_text, md5(t.embed_text) AS content_hash, t.model_extension,
        e.extension_version AS model_version
    FROM texts AS t
    JOIN duckdb_extensions() AS e ON e.extension_name = t.model_extension
), pending AS (
    SELECT k.* FROM keyed AS k
    ANTI JOIN agent.stream_hour_vector AS v USING (hour_id, content_hash, model_version)
    ORDER BY k.hour DESC, k.hour_id
    LIMIT 128
)
SELECT hour_id, content_hash, model_extension, model_version, embed(embed_text)::FLOAT[384] AS embedding,
    now() AS embedded_at
FROM pending;

WITH hours AS (SELECT count(hour_id) AS hours FROM agent.stream_hour),
vectors AS (SELECT count(hour_id) AS vectors FROM agent.stream_hour_vector)
SELECT h.hours, v.vectors, h.hours - v.vectors AS vectors_pending
FROM hours AS h POSITIONAL JOIN vectors AS v;

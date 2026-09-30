-- Local embeddings share the exact text used by BM25; bounded batches catch up each refresh.
LOAD quackformers;
CREATE TABLE IF NOT EXISTS agent.stream_vector (
    id VARCHAR PRIMARY KEY, content_hash VARCHAR, model_version VARCHAR,
    embedding FLOAT[384]
);

DELETE FROM agent.stream_vector
WHERE id NOT IN (SELECT id FROM agent.stream WHERE nullif(message_content, '') IS NOT NULL);

INSERT OR REPLACE INTO agent.stream_vector BY NAME
WITH model AS (
    SELECT extension_version AS model_version
    FROM duckdb_extensions() WHERE extension_name = 'quackformers'
), pending AS (
    SELECT s.id, s.message_content, sha256(s.message_content) AS content_hash, m.model_version
    FROM agent.stream s CROSS JOIN model m
    ANTI JOIN agent.stream_vector v
        ON s.id = v.id AND sha256(s.message_content) = v.content_hash
        AND m.model_version = v.model_version
    WHERE nullif(s.message_content, '') IS NOT NULL
    ORDER BY s.ts DESC NULLS LAST, s.id
    LIMIT 128
)
SELECT id, content_hash, model_version, embed(left(message_content, 2000))::FLOAT[384] AS embedding
FROM pending;

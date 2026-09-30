-- Incremental local BM25 postings. Run after agent.stream and agent.stream_day refresh.
LOAD fts;
CREATE SCHEMA IF NOT EXISTS agent;
CREATE TABLE IF NOT EXISTS agent.bm25_stopword AS
FROM read_parquet(getenv('HOME') || '/.duck/jobs/stopword.parquet');

CREATE TABLE IF NOT EXISTS agent.stream_bm25_document (
    id VARCHAR PRIMARY KEY, system VARCHAR, session_id VARCHAR, day DATE,
    block TIMESTAMPTZ, message_role VARCHAR, content_hash VARCHAR
);
CREATE TABLE IF NOT EXISTS agent.stream_bm25_length (id VARCHAR PRIMARY KEY, len BIGINT);
CREATE TABLE IF NOT EXISTS agent.stream_bm25_posting (id VARCHAR, term VARCHAR, tf BIGINT);

CREATE OR REPLACE TEMP TABLE bm25_source AS
SELECT id, system, session_id, day, block, message_role, message_content,
       sha256(message_content) AS content_hash
FROM agent.stream
WHERE message_content IS NOT NULL;

CREATE OR REPLACE TEMP TABLE bm25_stale AS
SELECT d.id
FROM agent.stream_bm25_document AS d
ANTI JOIN bm25_source AS s USING (id, content_hash);

DELETE FROM agent.stream_bm25_posting WHERE id IN (SELECT id FROM bm25_stale);
DELETE FROM agent.stream_bm25_length WHERE id IN (SELECT id FROM bm25_stale);
DELETE FROM agent.stream_bm25_document WHERE id IN (SELECT id FROM bm25_stale);

CREATE OR REPLACE TEMP TABLE bm25_fresh AS
SELECT s.*
FROM bm25_source AS s
ANTI JOIN agent.stream_bm25_document AS d USING (id, content_hash);

CREATE OR REPLACE TEMP TABLE bm25_term AS
WITH settings AS (
    SELECT '0123456789!@#$%^&*()_+={}[]:;<>,.?~\\/|''"`-' || chr(9) || chr(10) || chr(13) AS delimiters
), words AS (
    SELECT f.id, unnest(string_split(translate(lower(strip_accents(f.message_content)),
        s.delimiters, repeat(' ', len(s.delimiters))), ' ')) AS word
    FROM bm25_fresh AS f
    CROSS JOIN settings AS s
)
SELECT w.id, stem(w.word, 'porter') AS term
FROM words AS w
ANTI JOIN agent.bm25_stopword AS sw ON sw.sw = w.word
WHERE w.word <> '';

INSERT INTO agent.stream_bm25_posting BY NAME
SELECT id, term, count(term) AS tf
FROM bm25_term
GROUP BY ALL;

INSERT INTO agent.stream_bm25_length BY NAME
SELECT f.id, count(t.term) AS len
FROM bm25_fresh AS f
LEFT JOIN bm25_term AS t USING (id)
GROUP BY f.id;

INSERT INTO agent.stream_bm25_document BY NAME
SELECT id, system, session_id, day, block, message_role, content_hash
FROM bm25_fresh;

UPDATE agent.stream_bm25_document d
SET system = s.system, session_id = s.session_id, day = s.day, block = s.block, message_role = s.message_role
FROM bm25_source s
WHERE d.id = s.id
  AND (d.system, d.session_id, d.day, d.block, d.message_role)
      IS DISTINCT FROM (s.system, s.session_id, s.day, s.block, s.message_role);

SELECT len(list(id)) AS indexed_messages, sum(len) AS indexed_terms
FROM agent.stream_bm25_length;

-- ============================================================================
-- corpus.sql — the READ: 100% of every file the map admitted, sectioned, signed, wire-keyed.
--   duckdb waves.duckdb -f sql/corpus.sql          (after sql/crawl.sql)
-- ============================================================================
-- read_blob takes a list of paths and binds a literal, so the admitted paths — data,
-- node_map rows — pass through SQL text once: one explicit list per (root, folder, ext,
-- chunk), never a glob (a glob matches the FILESYSTEM; the list matches the MAP, so
-- policy-excluded junk cannot re-enter). Each list is one statement, self-dispatched to a
-- quackapi route this process serves. BLOB::VARCHAR is a TOTAL cast (invalid bytes come back
-- \x-escaped), so there is one tier and no read_errors table: nothing goes unread.
--
-- Whales become SECTIONS: any file over 24k chars explodes into 24k-char rows, each its own
-- signature and path#sN wire key — same shards, same waves, same honesty joins.
-- signature = md5(path|mtime|size|section): identity, concurrency, versioning in one value.
-- ============================================================================
LOAD hostfs; LOAD http_client; LOAD quackapi;
CREATE OR REPLACE ROUTE dispatch POST '/q' AS SELECT rows.* FROM query($q) rows;
FROM quackapi_serve(19503, host := '127.0.0.1');

CREATE OR REPLACE TABLE corpus AS
WITH files AS (
  SELECT root, parse_dirpath(path) AS folder, lower(file_extension(path)) AS ext, path
  FROM node_map
  WHERE NOT is_dir_flag AND file_size(path) <= 4000000
),
-- bin-pack each folder's list under one request: running list length // 7000 chars
chunks AS (
  SELECT *, sum(length(path) + 4) OVER (PARTITION BY root, folder, ext ORDER BY path) // 7000 AS chunk
  FROM files
),
stmts AS (
  SELECT root, folder, ext, chunk,
         format('SELECT filename AS path, content::VARCHAR AS content FROM read_blob([{}])',
                string_agg(format('{}{}{}', chr(39), path, chr(39)), ', ' ORDER BY path)) AS q
  FROM chunks GROUP BY ALL
),
-- the barrier: every list is read before any row below exists
fired AS (
  SELECT array_agg(struct_pack(root := root, folder := folder, ext := ext, chunk := chunk,
                               r := http_post_form('http://127.0.0.1:19503/q', MAP{}, MAP{'q': q}))
                   ORDER BY root, folder, ext, chunk) AS responses
  FROM stmts
),
reads AS (
  SELECT (u.e).root AS root, ((u.e).r).status AS status, row.path AS path, row.content AS content
  FROM fired CROSS JOIN UNNEST(responses) WITH ORDINALITY AS u(e, idx),
       unnest(from_json((((u.e).r).body ->> '$'), '[{"path":"VARCHAR","content":"VARCHAR"}]')) AS s(row)
  WHERE ((u.e).r).status = 200
),
whole AS (
  SELECT root, path, content, greatest(1, ceil(length(content) / 24000.0)::INT) AS sections FROM reads
),
sliced AS (
  SELECT * REPLACE (substring(content, section * 24000 + 1, 24000) AS content)
  FROM whole, unnest(range(sections)) AS t(section)
)
SELECT md5(format('{}|{}|{}|{}', path, file_last_modified(path), file_size(path), section)) AS signature,
       root, path, file_name(path) AS name, lower(file_extension(path)) AS ext,
       file_size(path) AS size_bytes, file_last_modified(path) AS mtime,
       section, sections,
       CASE WHEN sections = 1 THEN path ELSE format('{}#s{}', path, section) END AS wire_key,
       length(content) AS chars,
       left(replace(replace(content, chr(10), ' '), chr(13), ' '), 75) AS preview,
       content
FROM sliced;

FROM quackapi_stop();

-- VALIDATION — the read is total: unread (admitted ANTI JOIN corpus) MUST be 0.
SELECT (SELECT count(*) FROM node_map WHERE NOT is_dir_flag AND file_size(path) <= 4000000) AS admitted,
       count(DISTINCT path)                          AS corpus_files,
       count(*)                                      AS corpus_units,
       count(*) FILTER (WHERE sections > 1)          AS whale_sections,
       (SELECT count(*) FROM (SELECT path FROM node_map WHERE NOT is_dir_flag AND file_size(path) <= 4000000
                              EXCEPT SELECT path FROM corpus))               AS unread
FROM corpus;

-- ============================================================================
-- catalog.sql — every ext/<extension>.sql as rows, and one macro that finds the right one.
--   FLYING_ROOT="$PWD/shelf" duckdb :memory: -cmd ".read shelf/catalog.sql"   # -cmd keeps ~/.duckdbrc; never -init
-- The root is an environment variable read inline (house rule 4: no SET VARIABLE).
-- Each file carries a header of `-- @key: value` lines, with continuations on `--   ` lines.
-- No key is named anywhere below: the header is kept as (key, value) ROWS and widened by
-- PIVOT, so a new `-- @key:` appears on its own instead of being silently dropped.
-- ============================================================================
LOAD fts;

-- 1. raw: one row per file, the file whole.
-- read_text(glob) -> filename, content, size, last_modified
CREATE OR REPLACE TABLE flying_files AS
SELECT filename, content, size, last_modified
FROM read_text(getenv('FLYING_ROOT') || '/ext/*.sql');   -- FLYING_ROOT = this shelf/ directory; set on the shell line

-- 2. lines: one row per line, numbered. unnest(...) WITH ORDINALITY gives the number, so
-- there is no second string_split for generate_subscripts and no wrapper CTE.
CREATE OR REPLACE TABLE flying_lines AS
SELECT f.filename, u.ordinality AS line_no, u.unnest AS line
FROM flying_files f, unnest(string_split(f.content, chr(10))) WITH ORDINALITY AS u;

-- 3. header as (key, value) ROWS -- lossless, nothing enumerated.
-- A `-- @key: value` line is: key between '-- @' and the first colon, value after it.
-- position() + substr(), not string_split()[1] / [2:].
-- The header is the CONTIGUOUS block at the top of the file. That bound matters: body
-- comments are also indented ('--   ATTACH ...' in ducklake.sql), so a continuation rule
-- without it silently glues half the file onto the last key. header_ends is the first
-- non-header line per file; everything at or past it is body.
CREATE OR REPLACE TABLE flying_header_kv AS
WITH tagged AS (
  SELECT filename, line_no, line,
         starts_with(line, '-- @')                                AS is_key,
         starts_with(line, '-- @') OR starts_with(line, '--   ')  AS in_header
  FROM flying_lines
), bounded AS (
  SELECT * FROM (
    SELECT *, min(if(in_header, NULL, line_no)) OVER (PARTITION BY filename) AS header_ends
    FROM tagged
  )
  WHERE in_header AND (header_ends IS NULL OR line_no < header_ends)
), parts AS (
  SELECT *,
         if(is_key, substr(line, 5, position(':' IN line) - 5), NULL)        AS key_here,
         if(is_key, substr(line, position(':' IN line) + 2), trim(substr(line, 3))) AS text
  FROM bounded
), carried AS (
  SELECT *, last_value(key_here IGNORE NULLS) OVER (
              PARTITION BY filename ORDER BY line_no
              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS key
  FROM parts
)
SELECT filename, key, string_agg(text, ' ' ORDER BY line_no) AS value
FROM carried
WHERE key IS NOT NULL
GROUP BY filename, key;

-- 4. the wide table. PIVOT resolves the key set from the data, so this statement does not
-- name ext/rev/verified/functions/needs/tags/summary -- it just widens whatever is there.
-- It must be a TABLE, not a VIEW: DuckDB refuses a data-driven PIVOT in a view
-- ("PIVOT statements with pivot elements extracted from the data cannot be used in views"),
-- and pinning the key set with ON key IN (...) would re-introduce the enumeration.
CREATE OR REPLACE TABLE flying_header AS
PIVOT flying_header_kv ON key USING max(value) GROUP BY filename;

-- 5. the searchable document IS the file. No hand-concatenated doc string: the header lines
-- are already inside content, so indexing content indexes them too.
CREATE OR REPLACE TABLE flying_doc AS
SELECT filename, content AS doc FROM flying_files;

-- Every FTS behaviour pinned rather than left to an unstated default, matching
-- agent-stream/quack_stream_refresh.sql. `overwrite=1` is the FTS-owned lifecycle: a raw
-- DROP SCHEMA leaves the extension's registration behind and the next create then fails.
-- The default `ignore` regex intentionally splits code punctuation, so read_cloudwatch_logs
-- indexes as read/cloudwatch/logs. That is left alone -- exact code-shaped retrieval is a
-- cheap rerank of the candidate set below, not a second index.
PRAGMA create_fts_index(
  'flying_doc', 'filename', 'doc',
  stemmer = 'porter',
  stopwords = 'english',
  ignore = '(\\.|[^a-z])+',
  strip_accents = 1,
  lower = 1,
  overwrite = 1
);

-- 6. No macros yet. Plain queries until the shape is settled and a macro is justified.

-- find: BM25 ranks, exact phrase reranks above it. One statement.
--   WITH hits AS (
--     SELECT filename, fts_main_flying_doc.match_bm25(filename, :q) AS bm25
--     FROM flying_doc
--   )
--   SELECT contains(lower(f.content), lower(:q)) AS exact_phrase,
--          round(h.bm25, 2) AS bm25, h2.*
--   FROM hits h
--   JOIN flying_files f USING (filename)
--   JOIN flying_header h2 USING (filename)
--   WHERE h.bm25 IS NOT NULL
--   ORDER BY exact_phrase DESC, h.bm25 DESC;

-- by name, when the extension or function is already known:
--   SELECT * FROM flying_header
--   WHERE ext = :name OR contains(functions, :name) OR contains(tags, :name);

-- verification:
--   FROM flying_header_kv WHERE key = 'verified';   -- the lossless base, one row per key
--   SELECT * FROM flying_header ORDER BY ext;       -- the widened table, keys from the data

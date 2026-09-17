-- =============================================================================
-- declarative_pipeline.sql — three waves in ONE :memory: process, no external server:
--   A  discover   lsr from a literal root → prune by name → typed scalars
--   B  readers    one reader statement per file, chosen from a ROWS table, fired at this
--                 process's own httpserver (table functions bind literals; the scalar
--                 http_post_form takes columns — that is the whole trick)
--   C  lines      a second wave: read_lines over every file a reader returned
--
-- Verified DuckDB 1.5.5 osx_arm64 2026-09-17: hostfs, markdown, yaml, webbed, read_lines,
-- http_client, httpserver (community). What changed from the previous version: the seven-arm
-- CASE of || chains is a `readers` table joined on extension and ONE format(); quoting is done
-- once (qlit); the port is a params row; responses are kept whole (status + body) before
-- parsing; the listener is stopped at the end; the second root (quack-workbench/fixtures) is
-- gone from disk and is dropped rather than erroring.
-- =============================================================================
LOAD hostfs; LOAD markdown; LOAD yaml; LOAD webbed; LOAD read_lines;
LOAD http_client; LOAD httpserver;

-- params are a row, not a variable
CREATE OR REPLACE TEMP TABLE params AS
SELECT 19501                                                            AS port,
       ['node_modules', '.git', 'dump', '__pycache__', '.venv', 'venv', '.tox',
        'dist', 'build', '.mypy_cache', '.pytest_cache']                 AS skip_dirs,
       500000                                                            AS max_bytes;

-- readers are rows: extension → table function + its named arguments, stated in full
CREATE OR REPLACE TEMP TABLE readers AS
SELECT * FROM (VALUES
  ('.md',       'read_markdown',      'content_as_varchar := true, filename := true, include_filepath := true, normalize_content := true, extract_extensions := '''', extract_metadata := true, maximum_file_size := 2000000, flavor := ''gfm'', include_stats := true'),
  ('.markdown', 'read_markdown',      'content_as_varchar := true, filename := true, include_filepath := true, normalize_content := true, extract_extensions := '''', extract_metadata := true, maximum_file_size := 2000000, flavor := ''gfm'', include_stats := true'),
  ('.yaml',     'read_yaml_objects',  'strip_document_suffixes := true, sample_size := 20480, ignore_errors := true, maximum_file_size := 2000000, maximum_sample_files := -1, maximum_object_size := 16777216, multi_document := false, auto_detect := true'),
  ('.yml',      'read_yaml_objects',  'strip_document_suffixes := true, sample_size := 20480, ignore_errors := true, maximum_file_size := 2000000, maximum_sample_files := -1, maximum_object_size := 16777216, multi_document := false, auto_detect := true'),
  ('.html',     'read_html_objects',  'filename := true, maximum_file_size := 2000000, ignore_errors := true'),
  ('.htm',      'read_html_objects',  'filename := true, maximum_file_size := 2000000, ignore_errors := true'),
  ('.jsonl',    'read_json_objects',  'filename := true, ignore_errors := true, format := ''newline_delimited'''),
  ('.json',     'read_json_objects',  'filename := true, ignore_errors := true, format := ''array'''),
  ('.csv',      'read_csv',           'auto_detect := true'),
  ('.sql',      'read_text',          ''),
  ('.py',       'read_text',          ''),
  ('.sh',       'read_text',          ''),
  ('.txt',      'read_text',          '')
) AS t(ext, reader, args);

-- httpserve_start(host, port, auth) : loopback, no auth; the port comes from params
SELECT httpserve_start('127.0.0.1', port, '') AS listener FROM params;

CREATE OR REPLACE TEMP TABLE pipeline AS
WITH
-- ── A discover ───────────────────────────────────────────────────────────────
-- lsr(path, depth) -> path ; the root is a literal because lsr binds one
found AS (SELECT path FROM lsr('/Users/aloksubbarao/personal/self-dispatch', 2)),
files AS (
  SELECT path, absolute_path(path) AS absolute_path, file_name(path) AS file_name,
         file_extension(path) AS file_extension, file_size(path) AS file_size,
         hsize(file_size(path)) AS hsize, file_last_modified(path) AS file_last_modified
  FROM found, params
  WHERE NOT list_has_any(parse_path(path), skip_dirs)
    AND is_file(path) AND file_size(path) BETWEEN 1 AND max_bytes
),
-- ── B readers: the statement is a row, built once ────────────────────────────
-- qlit = the path as one single-quoted literal (embedded quotes doubled)
stmts AS (
  SELECT f.*, r.reader,
         format('SELECT {} AS path, * FROM {}({}{})',
                '''' || replace(f.path, '''', '''''') || '''',
                r.reader,
                '''' || replace(f.path, '''', '''''') || '''',
                CASE WHEN r.args = '' THEN '' ELSE ', ' || r.args END) AS q
  FROM files f JOIN readers r ON r.ext = f.file_extension
),
-- the barrier: every POST completes before any row below exists; ORDER BY = ordinality
fired AS (
  SELECT array_agg(struct_pack(path := path, reader := reader,
                               r := http_post_form(format('http://127.0.0.1:{}/', port), MAP{}, MAP{'q': q}))
                   ORDER BY path) AS responses
  FROM stmts, params
),
responses AS (
  SELECT (u.e).path AS path, (u.e).reader AS reader,
         ((u.e).r).status AS status, (((u.e).r).body ->> '$') AS ndjson, u.idx
  FROM fired CROSS JOIN UNNEST(responses) WITH ORDINALITY AS u(e, idx)
),
-- httpserver answers NDJSON: one line per reader row, values as strings; keep the line whole
reader_rows AS (
  SELECT path, reader, status, idx, line AS reader_row
  FROM responses, unnest(string_split(ndjson, chr(10))) AS s(line)
  WHERE status = 200 AND length(line) > 0
),
-- ── C lines: second wave over what the readers returned ──────────────────────
line_stmts AS (
  SELECT DISTINCT path,
         format('SELECT {} AS path, line_number, content, byte_offset FROM read_lines({})',
                '''' || replace(path, '''', '''''') || '''',
                '''' || replace(path, '''', '''''') || '''') AS q
  FROM reader_rows
),
line_fired AS (
  SELECT array_agg(struct_pack(path := path,
                               r := http_post_form(format('http://127.0.0.1:{}/', port), MAP{}, MAP{'q': q}))
                   ORDER BY path) AS responses
  FROM line_stmts, params
),
line_rows AS (
  SELECT (u.e).path AS path, ((u.e).r).status AS status,
         (line ->> '$.line_number')::BIGINT AS line_number,
         line ->> '$.content'                AS content,
         (line ->> '$.byte_offset')::BIGINT  AS byte_offset
  FROM line_fired CROSS JOIN UNNEST(responses) WITH ORDINALITY AS u(e, idx),
       unnest(string_split((((u.e).r).body ->> '$'), chr(10))) AS s(line)
  WHERE ((u.e).r).status = 200 AND length(line) > 0
),
lines_agg AS (
  SELECT path, array_agg(content ORDER BY line_number) AS lines, len(lines) AS n_lines
  FROM line_rows GROUP BY path
)
-- every column from A, the raw reader row from B, the lines from C; failures stay as rows
SELECT f.path, f.absolute_path, f.file_name, f.file_extension, f.file_size, f.hsize,
       f.file_last_modified, f.reader, f.q,
       r.status, r.reader_row, l.n_lines, l.lines
FROM stmts f
LEFT JOIN reader_rows r USING (path)
LEFT JOIN lines_agg  l USING (path)
ORDER BY f.path, r.idx;

SELECT httpserve_stop() AS stopped;

-- VALIDATION — failures are rows, not absences: every file got a status; statuses ≠ 200 are listed by name
SELECT count(DISTINCT path)                                   AS files,
       count(DISTINCT path) FILTER (WHERE status = 200)       AS files_read,
       list(DISTINCT path)  FILTER (WHERE status <> 200)      AS failed_paths,
       count(*)                                               AS reader_rows,
       sum(n_lines)                                           AS lines_total
FROM pipeline;

-- =============================================================================
-- declarative_ls.sql — progressive ls/lsr waves: ls the root, then lsr EACH child as a row.
-- lsr binds a literal, so the per-root call is self-dispatched: the statement is built per
-- row and POSTed to a quackapi route served by this same process, whose handler is
-- `query($q)`. The relation is the one you would write if the binder let you; the dispatch is
-- the only difference. Verified DuckDB 1.5.5, quackapi community, 2026-09-17.
-- =============================================================================
LOAD hostfs; LOAD http_client; LOAD quackapi;
-- the executor: one route, one handler, any statement; JSON array of typed rows back
CREATE OR REPLACE ROUTE dispatch POST '/q' AS SELECT rows.* FROM query($q) rows;
FROM quackapi_serve(19502, host := '127.0.0.1');

WITH
roots AS (
  SELECT path FROM ls('/Users/aloksubbarao/personal/self-dispatch') WHERE is_dir(path)
),
-- one lsr(child, 1) per root row, as text; chr(39) is the quote
stmts AS (
  SELECT path AS root,
         format('SELECT path FROM lsr({}{}{}, 1)', chr(39), path, chr(39)) AS q
  FROM roots
),
fired AS (
  SELECT array_agg(struct_pack(root := root,
                               r := http_post_form('http://127.0.0.1:19502/q', MAP{}, MAP{'q': q}))
                   ORDER BY root) AS responses
  FROM stmts
),
-- a JSON array of row objects back: unnest it, read by name
wave1 AS (
  SELECT (u.e).root AS root, ((u.e).r).status AS status, row.path AS path
  FROM fired CROSS JOIN UNNEST(responses) WITH ORDINALITY AS u(e, idx),
       unnest(from_json((((u.e).r).body ->> '$'), '[{"path":"VARCHAR"}]')) AS s(row)
  WHERE NOT list_has_any(parse_path(row.path), ['node_modules', '.git', '__pycache__', '.venv'])
)
SELECT root, status, path,
       is_dir(path) AS is_dir, is_file(path) AS is_file, file_name(path) AS file_name,
       file_extension(path) AS file_extension, file_size(path) AS file_size,
       file_last_modified(path) AS file_last_modified
FROM wave1
WHERE is_file(path) AND file_size(path) > 0
ORDER BY path;

FROM quackapi_stop();

-- @ext: quackapi
-- @rev: 398d42c (community build, DuckDB 1.5.5 osx_arm64)
-- @verified: 2026-09-17 on aloks-macbook-pro (quackpad branch pad-routes)
-- @functions: CREATE ROUTE, quackapi_serve, quackapi_stop, query(), http_post_form, read_csv (shellfs pipe)
-- @needs: http_client; shellfs + duck_tails for V1/V2/V10; a free loopback port (29321)
-- @tags: self-dispatch, per-row, fan-out, ordinality, determinism, process-per-row, literal-only wall
-- @source: pgedge-rag docs/techniques/self-dispatch-molecules.md; closure server/judge.sql
-- @summary: Ten verified variations of one duck posting SQL to its own /sql route (NDJSON):
--   per-row shell, per-row git_read, column-driven SELECT, dollar-quoted bodies, SELECT-only
--   refusal, nested dispatch, failure rows, the determinism trap (5 identical bodies = 1 call),
--   200-call fan-out re-aligned WITH ORDINALITY, and process-per-row via a printed command list.
-- selfdispatch.sql — a duck calling itself over loopback through a quackapi /sql route.
-- Turns literal-only table functions (shellfs, git_read, parse_*, crawl…) into per-row
-- calls, joined back. Shapes follow pgedge-rag/docs/techniques/self-dispatch-molecules.md:
--   * the posted body is a bare SELECT (query($q) enforces it: no LOAD, no DDL);
--   * array_agg(... ORDER BY rn) + UNNEST WITH ORDINALITY re-aligns responses to rows —
--     required here because quackapi_serve sets preserve_insertion_order=false;
--   * a macro over http_post is deterministic per argument tuple, so N samples of the
--     same body need a rep threaded in (V8) or they collapse to one call;
--   * failures are rows (status, body), never dropped (V7);
--   * try() around the unwrap so an empty body is NULL, not an exception.
--   * V10 is the third form: not HTTP but a built command list — one process per row —
--     for things that are session-global (a model, a LOAD) and so cannot ride loopback.
-- Verified 2026-09-17 on DuckDB 1.5.5 / quackapi 398d42c.

LOAD quackapi; LOAD http_client; LOAD json; LOAD shellfs; LOAD duck_tails;
CREATE OR REPLACE ROUTE sql POST '/sql' FORMAT ndjson AS SELECT * FROM query($q);
SELECT * FROM quackapi_serve(29321, host := '127.0.0.1');

-- the molecule: one scalar, one POST, one bare SELECT
CREATE OR REPLACE MACRO sd(q) AS http_post_form('http://127.0.0.1:29321/sql', MAP{}, MAP{'q': q});
-- ndjson body → list of JSON rows; NULL (not an error) when the body is empty or not 200
CREATE OR REPLACE MACRO sd_rows(r) AS
  CASE WHEN r->>'status' = '200'
       THEN try(list_filter(string_split(r->>'body', chr(10)), l -> l <> '')) END;

-- V1: per-row shell. shellfs is literal-only; inside the loopback its argument is a literal again.
SELECT '--- V1 per-row shell' AS v;
WITH cmds AS (SELECT rn, cmd FROM (VALUES (1,'echo alpha'), (2,'sw_vers -productVersion'), (3,'whoami')) t(rn, cmd)),
fired AS (
  SELECT array_agg(sd(format('SELECT * FROM read_csv(''{} |'', header=false, columns={{''out'':''VARCHAR''}})', cmd)) ORDER BY rn) AS rs
  FROM cmds)
SELECT u.idx AS rn, line->>'out' AS out
FROM fired, UNNEST(rs) WITH ORDINALITY AS u(r, idx), UNNEST(sd_rows(u.r)) v(line)
ORDER BY rn;

-- V2: per-row git_read (literal-only) joined back onto git_tree — scalar per row, no re-alignment needed
SELECT '--- V2 per-row git_read' AS v;
WITH files AS (SELECT file_path, git_uri FROM git_tree('/Users/aloksubbarao/Desktop/quackpad') WHERE kind = 'file' AND file_path LIKE 'sql/%'),
fired AS (SELECT file_path, sd(format('SELECT length(text) AS n FROM git_read(''{}'')', git_uri)) AS r FROM files)
SELECT file_path, (sd_rows(r)[1])->>'n' AS chars, r->>'status' AS status FROM fired ORDER BY file_path;

-- V3: column-driven SQL: describe a relation, build "SELECT <cols> LIMIT 4", fire it
SELECT '--- V3 describe -> select cols limit 4' AS v;
WITH cols AS (
  SELECT 'SELECT ' || string_agg(column_name, ', ') || ' FROM duckdb_settings() LIMIT 4' AS sql
  FROM (SELECT column_name FROM (DESCRIBE SELECT * FROM duckdb_settings()) LIMIT 3)),
fired AS (SELECT array_agg(sd(sql)) AS rs FROM cols)
SELECT line FROM fired, UNNEST(rs) WITH ORDINALITY AS u(r, idx), UNNEST(sd_rows(u.r)) v(line);

-- V4: dollar-quoted body so a row's own quotes survive
SELECT '--- V4 dollar-quoted body' AS v;
WITH src AS (SELECT unnest(['it''s', 'a "b"', 'c']) AS s),
fired AS (SELECT s, sd('SELECT length($blk$' || s || '$blk$) AS n') AS r FROM src)
SELECT s, (sd_rows(r)[1])->>'n' AS n FROM fired ORDER BY s;

-- V5: writes through self — query() is SELECT-only, so writes go to their own route
-- (see pad_routes.sql). This one 500s on purpose.
SELECT '--- V5 write via /sql is refused (SELECT-only)' AS v;
SELECT r->>'status' AS status FROM (SELECT sd('CREATE TABLE hits AS SELECT 1 AS i') AS r);

-- V6: nested: /sql runs a query that itself self-dispatches
SELECT '--- V6 nested self-dispatch' AS v;
SELECT sd_rows(r)[1] AS outer_row
FROM (SELECT sd('SELECT http_post_form(''http://127.0.0.1:29321/sql'', MAP{}, MAP{''q'':''SELECT 7 AS inner''})->>''body'' AS b') AS r);
-- (try() refuses to wrap a volatile call directly — sd_rows(sd(x)) is a binder error; go through a subquery)

-- V7: total capture: the failure is a row with its status; the message is on the server stderr
SELECT '--- V7 failure as a row' AS v;
SELECT r->>'status' AS status, sd_rows(r) IS NULL AS rows_null, left(r->>'body', 60) AS body FROM (SELECT sd('SELECT * FROM nope') AS r);

-- V8: the determinism trap: same body N times → ONE call, duplicated; a rep in the body → N calls
SELECT '--- V8 determinism: rep threaded in' AS v;
SELECT count(DISTINCT (sd_rows(r)[1])->>'t') AS distinct_calls_without_rep
FROM (SELECT sd('SELECT epoch_ns(now())::VARCHAR AS t') AS r FROM range(5));
SELECT count(DISTINCT (sd_rows(r)[1])->>'t') AS distinct_calls_with_rep
FROM (SELECT sd(format('SELECT epoch_ns(now())::VARCHAR AS t, {} AS rep', rep)) AS r FROM range(5) t(rep));

-- V9: fan-out 200 distinct bodies, re-aligned by ordinality
SELECT '--- V9 fan-out 200' AS v;
.timer on
WITH fired AS (SELECT array_agg(sd(format('SELECT {} AS i', i)) ORDER BY i) AS rs FROM range(200) t(i))
SELECT count(*) AS calls, bool_and((sd_rows(u.r)[1]->>'i')::INT = u.idx - 1) AS aligned
FROM fired, UNNEST(rs) WITH ORDINALITY AS u(r, idx);
.timer off

-- V10: process-per-row (closure/server/judge.sql shape). When the per-row thing is
-- session-global (open_prompt's model, a LOAD, a SET) it cannot be a column even over
-- loopback; so an inner duckdb PRINTS one env-carrying command per row, bash runs them
-- in parallel, each writes its own file, the outer query reads them back. No loop written
-- by hand: the command list is a query result.
SELECT '--- V10 process-per-row via built commands' AS v;
SELECT content AS dispatched FROM read_text($$rm -f /tmp/sd_v10_*.json; duckdb -noheader -list -c "
  COPY (
    SELECT printf('SD_I=%d duckdb -c \"COPY (SELECT getenv(''SD_I'')::INT AS i, getenv(''SD_I'')::INT * 2 AS dbl) TO ''/tmp/sd_v10_%d.json''\" &', i, i)
    FROM range(3) t(i)
    UNION ALL SELECT 'wait'
  ) TO '/dev/stdout' (FORMAT csv, HEADER false, QUOTE '')" | bash |$$);
SELECT i, dbl FROM read_json('/tmp/sd_v10_*.json') ORDER BY i;
SELECT * FROM quackapi_stop(29321);

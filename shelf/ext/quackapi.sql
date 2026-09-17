-- @ext: quackapi
-- @rev: 398d42c (community build, DuckDB 1.5.5 osx_arm64) — README on main describes newer builds
-- @verified: 2026-09-17
-- @functions: CREATE ROUTE, quackapi_request, quackapi_serve, quackapi_stop, quackapi_routes, query()
-- @needs: http_client (the per-row POST; this build has no quackapi_post / quackapi_wait)
-- @tags: self-dispatch, orchestration, dynamic sql, fan-out, routes are DDL
-- @summary: The query is the orchestrator. One route runs whatever SQL it is POSTed; every outer
--   row builds a query string and http_post()s it back to this same process, so the inner
--   reader gets a literal argument that came from a row. rows → SQL → rows → next stage.
LOAD quackapi;
LOAD http_client;

-- Parser note: CREATE ROUTE is registered by LOAD; feed LOAD first in a sequential session.
-- `duckdb -c "LOAD quackapi; CREATE ROUTE …"` in one string fails with "syntax error at or near ROUTE".

-- The dispatch route. $sql binds from the JSON body field "sql"; query() runs it and the
-- result set is the response. A route is DDL: it lives in this process until DROP ROUTE.
CREATE ROUTE q POST '/q' AS SELECT * FROM query($sql);

-- In-process, no listener: quackapi_request(method, path, body) -> status, body (BLOB)
SELECT status, body::VARCHAR FROM quackapi_request('POST', '/q', '{"sql": "SELECT 42 AS answer"}');

-- Listener on localhost. quackapi_serve(port) returns immediately with listen_url.
SELECT listen_url FROM quackapi_serve(8765);

-- Self-dispatch, one query per outer row. http_post(url, headers MAP, body VARCHAR) -> STRUCT(status, reason, body)
-- is a scalar, so it fires per row; quackapi_request is a table function and cannot take a column.
CREATE TABLE t AS SELECT range AS id, 'row' || range AS name FROM range(5);
SELECT r.id,
       (http_post('http://127.0.0.1:8765/q', MAP {'Content-Type': 'application/json'},
                  json_object('sql', 'SELECT name FROM t WHERE id = ' || r.id)::VARCHAR)).body AS out
FROM t r;

-- The ETL shape: a row carries a path; the dispatched SQL hands that path to a reader as a
-- literal. chr(39) is the quote; doubling it inside the string is the only escaping needed.
SELECT p.path,
       (http_post('http://127.0.0.1:8765/q', MAP {'Content-Type': 'application/json'},
                  json_object('sql', 'SELECT count(*) AS n FROM read_csv(''' || p.path || ''', header := false, delim := chr(7), columns := {line: ''VARCHAR''})')::VARCHAR)).body AS out
FROM (VALUES ('/tmp/dh/be3.txt'), ('/tmp/dh/deploy_backend.txt')) p(path);
-- → [{"n":14356}] and [{"n":188}]: the inner read_csv ran on a path it never saw as a literal in this file.

-- The response body is JSON text; land it whole, then read it typed: unnest(from_json(out, '[{"n":"BIGINT"}]')).

SELECT status FROM quackapi_stop(8765);

-- Not in this build (398d42c): quackapi_post, quackapi_wait, `block := true`. Readiness is a
-- retry loop on http_get('http://127.0.0.1:8765/health'), or just serve → wait a beat → post.
-- Behind the quack server (9494) this would be `dev.query($$SELECT * FROM quackapi_serve(8000)$$)`
-- once quackapi is in setup.sql; the listener then outlives the client session.

-- @ext: http_client
-- @rev: community build on DuckDB 1.5.5 osx_arm64 (local client only; not in setup.sql)
-- @verified: 2026-09-17 — http_post per row against a local quackapi route (ext/quackapi.sql); http_head returns response headers incl. retry-after
-- @functions: http_get, http_post, http_post_form, http_head
-- @needs: nothing; the dev server needs `INSTALL http_client FROM community; LOAD http_client;` in setup.sql to use it there
-- @tags: post, graphql, linear, api, self-dispatch, headers, retry-after, rate limit
-- @summary: Scalar HTTP: fires once per row, so it is the fan-out primitive (rows → requests → rows).
--   read_json (ext/httpfs.sql) is for GET JSON; this is for POST, custom headers, and per-row dispatch.
LOAD http_client;

-- http_get(url [, headers MAP, params MAP]) -> STRUCT(status INT, reason VARCHAR, body VARCHAR)
SELECT (r).status, (r).reason, ((r).body::JSON)->>'url' AS url
FROM (SELECT http_get('https://httpbin.org/get', headers => MAP {'accept': 'application/json'}, params => MAP {'limit': '1'}) AS r);

-- http_post(url, headers MAP, body VARCHAR) -> STRUCT(status, reason, body)
-- Linear is GraphQL over POST; the window rides in the filter. Land the body whole as JSON, unnest after.
SET VARIABLE win_start = now() - INTERVAL 1 DAY;
CREATE TEMP TABLE linear_page AS
SELECT (r).status, (r).body::JSON AS payload
FROM (SELECT http_post('https://api.linear.app/graphql',
        MAP {'Authorization': getenv('LINEAR_API_KEY'), 'Content-Type': 'application/json'},
        json_object('query', '{ issues(first: 100, filter: { updatedAt: { gt: "' || getvariable('win_start')::TIMESTAMP::VARCHAR || '" } }) '
          || '{ nodes { id identifier title priority createdAt updatedAt completedAt branchName url state { name type } assignee { name email } team { key } project { name } labels { nodes { name } } } } }')::VARCHAR) AS r);
SELECT n->>'identifier' AS id, n->>'title' AS title, n->'state'->>'name' AS state, n->>'updatedAt' AS updated_at
FROM (SELECT unnest(from_json(payload->'data'->'issues'->'nodes', '["JSON"]')) AS n FROM linear_page);

-- Response headers: http_get/http_post return status+reason+body only. http_head(url) returns the headers of a HEAD
-- request as a JSON string — retry-after, x-ratelimit-remaining, link (pagination) — a separate request, not the GET's.
SELECT ((r).headers::JSON)->>'retry-after' AS retry_after FROM (SELECT http_head('https://httpbin.org/response-headers?retry-after=7') AS r);

-- Self-dispatch (the orchestration primitive): each row POSTs a SQL string to a quackapi route in this process.
--   see ext/quackapi.sql — CREATE ROUTE q POST '/q' AS SELECT * FROM query($sql); quackapi_serve(8765)
SELECT d.day,
       (http_post('http://127.0.0.1:8765/q', MAP {'Content-Type': 'application/json'},
                  json_object('sql', 'SELECT count(*) AS n FROM read_json(''https://api.github.com/repos/inframe-risk/inframe/actions/runs?created=' || d.day || ''')')::VARCHAR)).body AS out
FROM (SELECT (DATE '2026-09-10' + INTERVAL (i) DAY)::DATE AS day FROM range(7) t(i)) d;
-- → seven requests, one per day: that is the backfill loop, in SQL, with no orchestrator.

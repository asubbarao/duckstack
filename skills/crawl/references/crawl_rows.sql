-- crawl_rows.sql: one page per row, fetched by raw crawl() self-dispatched with literal arguments.
-- Run it on dev (mcp__dev__query, or POST 127.0.0.1:9495/sql). Verified 2026-09-29, crawler 7725ede, DuckDB 1.5.5.
--
-- crawl_url is allowed, but not with the source column passed directly: a binder complaint means the per-row
-- self-dispatch step was skipped. This example chooses crawl() for its richer receipt. Either function must be rendered
-- with the URL as a literal and posted to the selected endpoint; each receipt carries its own seed, so failures stay rows.
--
-- crawl(url|urls, cache := true, cache_ttl := 24 /*h*/, timeout := 30 /*s*/, delay := 1000 /*ms*/, workers := 4,
--       batch_size := 10, respect_robots := true, follow := '', max_depth := 1, state_table := '',
--       user_agent := crawler_user_agent, max_results := -1, extract := [])
--   -> url, status, content_type, html STRUCT(document, js, opengraph, schema, readability), error, extract,
--      response_time_ms, depth
-- max_results := 1 bounds a crawl() seed to one row. A crawl_url variant also gets an outer LIMIT <= 10 while testing.
-- Seeds only: follow := '' and max_depth := 1. Widen only after looking at the landed rows.
INSTALL http_client FROM community;
LOAD http_client;

WITH seeds AS (
    -- the parameter row: endpoint, bounds and user agent ride beside each url (no VALUES, no singleton cross join)
    SELECT url, 'http://127.0.0.1:9495/sql' AS endpoint, 30 AS timeout_s, 0 AS delay_ms, 1 AS workers,
           'InFrame crawl-rows/1.0' AS user_agent
    FROM (SELECT 'https://duckdb.org/community_extensions/extensions/duckpgq' AS url
          UNION ALL SELECT 'https://duckdb.org/community_extensions/extensions/no_such_extension_zz') u
    ORDER BY url
    LIMIT 10
),
statements AS (
    SELECT *, replace(replace(replace(replace(replace($t$
SELECT now()::VARCHAR AS fetched_at, url, status, content_type, html.document AS document, error, response_time_ms, depth
FROM crawl('@URL@', cache := false, cache_ttl := 24, timeout := @TIMEOUT@, delay := @DELAY@, workers := @WORKERS@,
           batch_size := 1, respect_robots := true, follow := '', max_depth := 1, state_table := '',
           user_agent := '@UA@', max_results := 1, "extract" := []::VARCHAR[])$t$,
        '@URL@', url), '@TIMEOUT@', timeout_s::VARCHAR), '@DELAY@', delay_ms::VARCHAR), '@WORKERS@', workers::VARCHAR),
        '@UA@', user_agent) AS statement
    FROM seeds
),
fired AS (
    -- the array_agg is the barrier: every post completes before a row below exists
    SELECT array_agg(struct_pack(seed := url, statement := statement,
                                 r := http_post(endpoint, MAP {'Content-Type': 'application/json'}, json_object('sql', statement))) ORDER BY url) AS receipts
    FROM statements
),
landed AS (
    -- /sql answers with the row array as a JSON string; a non-200 receipt keeps its body as the error
    SELECT (u.e).seed AS seed, ((u.e).r).status AS dispatch_status,
           CASE WHEN ((u.e).r).status = 200
                THEN from_json(((u.e).r).body ->> '$',
                    '[{"fetched_at":"VARCHAR","url":"VARCHAR","status":"INTEGER","content_type":"VARCHAR","document":"VARCHAR","error":"VARCHAR","response_time_ms":"BIGINT","depth":"INTEGER"}]')
                ELSE [{'fetched_at': NULL, 'url': NULL, 'status': NULL, 'content_type': NULL, 'document': NULL,
                       'error': ((u.e).r).body, 'response_time_ms': NULL, 'depth': NULL}] END AS pages
    FROM fired CROSS JOIN UNNEST(receipts) AS u(e)
)
SELECT seed, dispatch_status, p.status, p.content_type, len(p.document) AS doc_chars, left(p.document, 40) AS preview,
       p.error, p.response_time_ms, p.depth
FROM landed CROSS JOIN UNNEST(pages) AS pg(p)
ORDER BY seed;
-- Verify: 2 seeds -> 2 rows; the 200 row has doc_chars > 0 and error NULL; the missing page is a row with its status/error.
-- To land raw: wrap as CREATE OR REPLACE TABLE raw_<name> AS SELECT * EXCLUDE (...) and keep `document` whole.

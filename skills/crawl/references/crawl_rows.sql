-- crawl_rows.sql: one page per row, fetched by curl through shellfs, one self-dispatched INSERT per url.
-- Run on dev (mcp__dev__query). Verified 2026-10-09: the same form is the hourly catalog job in server/setup.sql.
-- The receipt is the HTTP status of the dispatched statement; the page itself lands in lake.agents.ext_fetch
-- and is read back through agents.ext_page (newest good fetch per url). A failed fetch (curl --fail) lands no row.
WITH due AS (
    SELECT url FROM UNNEST(['https://duckdb.org/community_extensions/extensions/duckpgq',
                            'https://duckdb.org/community_extensions/extensions/no_such_extension_zz']) AS t(url)
)
SELECT url, http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', tera_render($t$
INSERT INTO lake.agents.ext_fetch BY NAME
SELECT '{{ url }}' AS url, now() AS fetched_at, json_object('status', 200, 'body', content) AS response
FROM read_text('curl -sSL --fail --max-time 30 {{ url }} |')
$t$, json_object('url', url), autoescape := false))) ->> '$.status' AS status
FROM due;
-- Expect: duckpgq 200 (landed), no_such_extension_zz 422 (curl --fail on the 404; nothing landed).

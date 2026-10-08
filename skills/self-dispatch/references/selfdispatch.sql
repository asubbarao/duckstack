-- selfdispatch.sql: every supported way to run a statement that SQL wrote, side by side. The rows are two folders; each transport
-- builds `FROM ls('<folder>')` for each row and runs it somewhere, and keeps the receipt. Run it on the dev server.
-- A dispatched SELECT carries its own LIMIT: /sql returns 20 rows otherwise.
--
-- http_post(url VARCHAR, headers MAP, body JSON [, params MAP]) -> JSON {status, reason, body}      http_client
-- http_get(url VARCHAR [, headers MAP, params MAP]) -> JSON {status, reason, body}                   http_client
-- tera_render(template VARCHAR [, context JSON]) -> VARCHAR; html_unescape(VARCHAR) -> VARCHAR       tera, webbed
-- quack_query(uri, sql, token := VARCHAR) -> rows (constant arguments only)                         quack
-- httpserve_start(host VARCHAR, port INTEGER, auth VARCHAR) -> VARCHAR; httpserve_stop()            httpserver
INSTALL httpserver FROM community; LOAD httpserver;
-- A throwaway second HTTP endpoint inside this process (the ClickHouse-style httpserver extension). A CTAS, not a
-- SELECT: /sql returns the FIRST statement that produces rows, and that must be the comparison below.
CREATE OR REPLACE TEMP TABLE _httpserver AS SELECT httpserve_start('127.0.0.1', 9581, '') AS started;

WITH folders AS (
    SELECT path, ['FROM ls(', chr(39) || path || chr(39), ')', 'LIMIT 100000'] AS parts, array_to_string(parts, ' ') AS statement
    FROM ls('/Users/aloksubbarao/duckdb-skills/skills') WHERE is_dir(path) LIMIT 2
),
-- 1. JSON POST: JSON body to this server's quackapi /sql. The default; nothing but concatenation and one POST.
naked AS (
    SELECT path, 'JSON /sql' AS transport, statement,
        http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', statement)) AS receipt
    FROM folders
),
-- 2. tera: the statement is a template file rendered per row; html_unescape undoes tera's escaping of the quotes.
tera AS (
    SELECT path, 'tera ls.tera' AS transport, html_unescape(tera_render(t.content, json_object('dir', path))) AS statement,
        http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', statement)) AS receipt
    FROM folders, read_text('/Users/aloksubbarao/duckdb-skills/skills/self-dispatch/references/ls.tera') t
),
-- 3. printf: shown because older files use it; the placeholder hides the statement's shape, so prefer 1.
printf AS (
    SELECT path, 'printf' AS transport, printf('FROM ls(%s) LIMIT 100000', chr(39) || path || chr(39)) AS statement,
        http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', statement)) AS receipt
    FROM folders
),
-- 4. quack server: quack_query only takes constants, so the call itself is the generated statement, carried by /sql.
--    Point the URI at another agent's port and the same row runs on that DuckDB instead.
quack AS (
    SELECT path, 'quack_query 9494' AS transport,
        'FROM quack_query(' || chr(39) || 'quack:localhost:9494' || chr(39) || ', $q$' || statement || '$q$, token := getenv(' || chr(39) || 'QUACK_TOKEN' || chr(39) || '))' AS statement,
        http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', statement)) AS receipt
    FROM folders
),
-- 5. httpserver: GET with the statement as the `query` parameter; the body is newline-delimited JSON rows.
httpserver AS (
    SELECT path, 'httpserver 9581' AS transport, statement,
        http_get('http://127.0.0.1:9581/', MAP {}, MAP {'query': statement, 'default_format': 'JSONEachRow'}) AS receipt
    FROM folders
)
SELECT transport, path, statement, receipt ->> '$.status' AS status, length(receipt ->> '$.body') AS body_chars, left(receipt ->> '$.body', 120) AS body_head
FROM (FROM naked UNION ALL BY NAME FROM tera UNION ALL BY NAME FROM printf
    UNION ALL BY NAME FROM quack UNION ALL BY NAME FROM httpserver)
ORDER BY transport, path;
CREATE OR REPLACE TEMP TABLE _httpserver AS SELECT httpserve_stop() AS stopped;

-- The three self-dispatch templates, one example each. Every query is the same three steps:
--   1. declare everything in the first CTE (rows; options as text; values prequoted),
--   2. rendered: tera_render('<template>.tera', c::JSON) — Tera only fills holes,
--   3. dispatched: array_agg(selfdispatch(sql)), then CROSS JOIN UNNEST(receipts).
-- shell: commands or files, any reader, many sources per statement, jq on/off | sql: in the database |
-- bash_loop_fallback_method: a FALLBACK, listed by the audit wherever it is used.
-- A pipeline of stages, each fed by the last one's receipts: ../references/five_stage_pipeline.sql.
-- Verified on dev 2026-10-17.

-- 1. shell: one row per statement. A command ends with ' |', a file is its path; jq appends only '| jq -c ''.[]'''.
WITH sources AS (
    SELECT 'read_csv' AS reader, false AS jq, ', header := false' AS options,
           ['find /private/tmp -maxdepth 1 -type d', 'find /Users/aloksubbarao/inframe -maxdepth 1 -type d'] AS commands, [] AS files
    UNION ALL
    SELECT 'read_json', true, ', format := ''newline_delimited''',      -- gh --paginate prints arrays back to back
           ['gh api --paginate ''repos/duckdb/duckdb-quack/branches?per_page=100'''], []
    UNION ALL
    SELECT 'read_json', false, '', ['curl -sS --fail --max-time 30 https://api.staging.inframerisk.net/api/v1/utils/health-check/'], []
    UNION ALL
    SELECT 'read_text', false, '', [], ['/Users/aloksubbarao/.duck/logs/server-exits.log', '/Users/aloksubbarao/.duck/logs/reload-events.log']
    UNION ALL
    SELECT 'read_blob', false, '', [], ['/System/Library/CoreServices/SystemVersion.plist']
), declared AS (
    SELECT reader, options,
           list_concat(list_transform(commands, c -> concat_ws(' ', c, CASE WHEN jq THEN '| jq -c ''.[]''' END, '|')), files) AS sources
    FROM sources
), rendered AS (
    SELECT tera_render('shell.tera', c::JSON, autoescape := false,
                       template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS sql
    FROM declared AS c
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

-- 2. sql: in the database; the names come from information_schema. DDL, DML and PRAGMA have the same shape.
WITH tables AS (
    SELECT table_schema, table_name, 5 AS row_limit FROM information_schema.tables WHERE table_name LIKE 'chrome_%'
), rendered AS (
    SELECT tera_render('sql.tera', c::JSON, autoescape := false,
                       template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS sql
    FROM tables AS c
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

-- 4. network: one request per row to another host; here another DuckDB's /sql. The row's own columns ride with
--    its receipt: group by them next to array_agg(selfdispatch(sql)), then read target next to receipt.*.
WITH requests AS (
    SELECT 'other_host' AS target, 'http://127.0.0.1:9495/sql' AS url, json_object('sql', 'SELECT 42 AS answer')::VARCHAR AS body
), rendered AS (
    SELECT target, tera_render('network.tera', c::JSON, autoescape := false,
                               template_path := concat_ws('/', getenv('HOME'), '.duck/deploy/skills/self-dispatch/templates/*.tera')) AS sql
    FROM requests AS c
), dispatched AS (
    SELECT target, array_agg(selfdispatch(sql)) AS receipts FROM rendered GROUP BY ALL
)
SELECT target, receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

-- 3. bash_loop_fallback_method: a FALLBACK. This example has a row source, so example 1 is the right answer;
--    it is here only to show the call. The audit lists every use of this template.
WITH counts AS (
    SELECT ['server-exits.log', 'launchd.err'] AS items, 'wc -l < ~/.duck/logs/$item' AS body
), rendered AS (
    SELECT tera_render('bash_loop_fallback_method.tera', c::JSON, autoescape := false,
                       template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS sql
    FROM counts AS c
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

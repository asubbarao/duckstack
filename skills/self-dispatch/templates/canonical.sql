-- The five canonical self-dispatch templates, one example each. Every query is the same three CTEs:
--   1. declare everything (rows; the command as text; options as text; values prequoted),
--   2. rendered: tera_render('<template>.tera', c::JSON) — Tera only fills holes,
--   3. dispatched: array_agg(selfdispatch(sql)), then CROSS JOIN UNNEST(receipts).
-- shell: one command | sql: in the database | network: curl out | jq_array_to_lines: only when read_json can't read
-- the output whole | bash_loop_fallback_method: a FALLBACK, listed by the audit wherever it is used.
-- Verified on dev 2026-10-17.

-- 1. shell: one command, one reader.
WITH listings AS (
    SELECT 'read_csv' AS reader, concat_ws(' ', 'find', quote_literal(path), '-maxdepth 1 -type d') AS command, ', header := false' AS options
    FROM (SELECT unnest(['/private/tmp', '/Users/aloksubbarao/inframe']) AS path)
), rendered AS (
    SELECT tera_render('shell.tera', c::JSON, autoescape := false,
                       template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS sql
    FROM listings AS c
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

-- 2. jq_array_to_lines: gh api --paginate prints one array per page back to back, which read_json can't read whole;
--    jq only splits them into lines. Output read_json can read (a plist via plutil, one API page) goes through shell.tera.
WITH pages AS (
    SELECT concat_ws(' ', 'gh api --paginate', quote_literal(endpoint)) AS command, '.' AS array
    FROM (SELECT unnest(['repos/duckdb/duckdb-quack/branches?per_page=100']) AS endpoint)
), rendered AS (
    SELECT tera_render('jq_array_to_lines.tera', c::JSON, autoescape := false,
                       template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS sql
    FROM pages AS c
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

-- 3. sql: in the database; the names come from information_schema. DDL, DML and PRAGMA have the same shape.
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

-- 4. network: another host, through curl.
WITH endpoints AS (
    SELECT 'read_json' AS reader, quote_literal(url) AS url, '' AS options
    FROM (SELECT unnest(['https://api.staging.inframerisk.net/api/v1/utils/health-check/',
                         'https://api.app.inframerisk.com/api/v1/utils/health-check/']) AS url)
), rendered AS (
    SELECT tera_render('network.tera', c::JSON, autoescape := false,
                       template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS sql
    FROM endpoints AS c
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

-- 5. bash_loop_fallback_method: a FALLBACK. This example has a row source, so example 1's shape is the right answer;
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

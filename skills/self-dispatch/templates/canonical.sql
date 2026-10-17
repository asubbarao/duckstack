-- The five canonical self-dispatch templates, one example each. Every query is the same three CTEs:
--   1. declare everything (rows; the command as text; options as text; values prequoted),
--   2. rendered: tera_render('<template>.tera', c::JSON) — Tera only fills holes,
--   3. dispatched: array_agg(selfdispatch(sql)), then CROSS JOIN UNNEST(receipts).
-- shell 1 command | pipeline command | jq | sql in the database | network curl out | loop a bash loop (rare).
-- Verified on dev 2026-10-17 (all five in one dispatch).

-- 1. shell: one command, one reader.
WITH listings AS (
    SELECT 'read_csv' AS reader, printf('find %s -maxdepth 1 -type d', quote_literal(path)) AS command, ', header := false' AS options
    FROM (SELECT unnest(['/private/tmp', '/Users/aloksubbarao/inframe']) AS path)
), rendered AS (
    SELECT tera_render('shell.tera', c::JSON, autoescape := false,
                       template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS sql
    FROM listings AS c
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

-- 2. pipeline: a command through jq, one JSON object per line.
WITH plists AS (
    SELECT 'plutil -convert json -o - ' || quote_literal(path) AS command, '{name: .ProductName, version: .ProductVersion}' AS jq
    FROM (SELECT unnest(['/System/Library/CoreServices/SystemVersion.plist']) AS path)
), rendered AS (
    SELECT tera_render('pipeline.tera', c::JSON, autoescape := false,
                       template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS sql
    FROM plists AS c
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

-- 5. loop: a bash loop, only when it really is the simplest thing (rows usually replace it).
WITH counts AS (
    SELECT ['server-exits.log', 'launchd.err'] AS items, 'wc -l < ~/.duck/logs/$item' AS body
), rendered AS (
    SELECT tera_render('loop.tera', c::JSON, autoescape := false,
                       template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS sql
    FROM counts AS c
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

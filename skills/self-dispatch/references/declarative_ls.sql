-- declarative_ls.sql: crawl a folder tree by self-dispatch, pruning before descending.
-- A wave lists one level. Its folders are filtered by name, and only the survivors are listed in
-- the next wave, by posting one `ls` statement per folder back to this same server. Nothing under a
-- pruned folder (.git, .venv, node_modules) is ever read. Each extra level is one more post/wave
-- pair, copied and renumbered. Keep every column; a consumer filters.
--
-- ls(path VARCHAR) -> TABLE(path)                        hostfs: one directory, not recursive
-- is_dir(path) -> BOOLEAN, file_name(path) -> VARCHAR    hostfs scalars
-- http_post(url VARCHAR, headers MAP(VARCHAR, VARCHAR), body JSON) -> JSON {status, reason, body}
--                                                        http_client; params := MAP is the 4th optional arg
-- from_json(json, structure) -> typed value
-- The dispatched SELECT carries an explicit LIMIT because /sql caps an unlimited SELECT at 20 rows.
-- Run it as a statement on the dev server (MCP query_no_limit, or self-dispatch the file text).
WITH wave1 AS (
    SELECT '' AS parent, path, is_dir(path) AS is_dir, file_name(path) AS name
    FROM ls('/Users/aloksubbarao/duckdb-skills')
), post2 AS (
    SELECT array_agg(http_post(
        'http://127.0.0.1:9495/sql',
        MAP {'Content-Type': 'application/json'},
        json_object('sql', printf($$SELECT '%s' AS parent, path, is_dir(path) AS is_dir, file_name(path) AS name FROM ls('%s') LIMIT 100000$$, path, path))
    )) AS receipts
    FROM wave1
    WHERE is_dir AND NOT starts_with(name, '.') AND name NOT IN ('node_modules', '__pycache__', 'venv')
), wave2 AS (
    SELECT receipt ->> '$.status' AS status, entry.*
    FROM post2
    CROSS JOIN UNNEST(receipts) AS r(receipt)
    CROSS JOIN UNNEST(from_json(receipt ->> '$.body', '[{"parent":"VARCHAR","path":"VARCHAR","is_dir":"BOOLEAN","name":"VARCHAR"}]')) AS e(entry)
), post3 AS (
    SELECT array_agg(http_post(
        'http://127.0.0.1:9495/sql',
        MAP {'Content-Type': 'application/json'},
        json_object('sql', printf($$SELECT '%s' AS parent, path, is_dir(path) AS is_dir, file_name(path) AS name FROM ls('%s') LIMIT 100000$$, path, path))
    )) AS receipts
    FROM wave2
    WHERE is_dir AND NOT starts_with(name, '.') AND name NOT IN ('node_modules', '__pycache__', 'venv')
), wave3 AS (
    SELECT receipt ->> '$.status' AS status, entry.*
    FROM post3
    CROSS JOIN UNNEST(receipts) AS r(receipt)
    CROSS JOIN UNNEST(from_json(receipt ->> '$.body', '[{"parent":"VARCHAR","path":"VARCHAR","is_dir":"BOOLEAN","name":"VARCHAR"}]')) AS e(entry)
)
SELECT 1 AS wave, * FROM wave1
UNION ALL BY NAME SELECT 2 AS wave, * FROM wave2
UNION ALL BY NAME SELECT 3 AS wave, * FROM wave3

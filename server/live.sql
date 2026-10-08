-- live.sql: idempotent definitions only (CREATE OR REPLACE VIEW / MACRO). setup.sql .reads it at start and a
-- one-minute cron posts its current text to /sql; the startup watcher also restarts for an edit here because
-- it is part of the startup chain.
-- Nothing here may serve a port, register a cron or publish an MCP tool; those stay in setup.sql.

CREATE SCHEMA IF NOT EXISTS agents;
CREATE SCHEMA IF NOT EXISTS meta;

-- post_file(path): post a .sql file's current text to this server's /sql; the receipt is the row. cron.sql uses it.
-- http_post(url VARCHAR, headers MAP, body JSON [, params MAP]) -> JSON {status, reason, body}; read_text(path|glob)
CREATE OR REPLACE MACRO post_file(p) AS TABLE
    SELECT filename, http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', content)) AS receipt
    FROM read_text(p);

-- dispatch_sql(statements, endpoint): one form POST per statement, receipts in position order. The MCP tools call these.
CREATE OR REPLACE MACRO agents.dispatch_sql(statements, endpoint := 'http://127.0.0.1:9495/sql') AS TABLE
    WITH posted AS (
        SELECT array_agg({position: i, statement: s, response: http_post_form(endpoint, MAP {}, MAP {'sql': s})} ORDER BY i) AS receipts
        FROM (SELECT unnest(statements) AS s, generate_subscripts(statements, 1) AS i)
    )
    SELECT r.position, r.statement, r.response.status AS status, r.response.body ->> '$' AS body
    FROM posted, unnest(receipts) AS d(r) ORDER BY r.position;
-- dispatch_sequence: dependent statements as ONE ordered body.
CREATE OR REPLACE MACRO agents.dispatch_sequence(statements, endpoint := 'http://127.0.0.1:9495/sql') AS TABLE
    FROM agents.dispatch_sql([array_to_string(statements, chr(10) || ';' || chr(10))], endpoint := endpoint);

-- host_processes(): ps as rows; the raw line is kept beside the split fields (no header with `=`).
CREATE OR REPLACE MACRO agents.host_processes() AS TABLE
    WITH p AS (
        SELECT line, list_filter(string_split(trim(line), ' '), x -> x <> '') AS parts
        FROM read_text('ps -axo pid=,ppid=,etime=,%cpu=,%mem=,comm= |'), unnest(string_split(content, chr(10))) AS u(line)
        WHERE trim(line) <> ''
    )
    SELECT parts[1]::BIGINT AS pid, parts[2]::BIGINT AS ppid, parts[3] AS elapsed, parts[4]::DOUBLE AS cpu_percent,
        parts[5]::DOUBLE AS memory_percent, array_to_string(parts[6:], ' ') AS command, line
    FROM p;

-- agent_sql_guide: verified SQL to copy, one row per pattern; sql is read from the file that was run, never retyped.
-- Add a row: CREATE OR REPLACE TABLE agent_sql_guide AS FROM agent_sql_guide UNION ALL BY NAME SELECT <name>, <sql>, <notes>, <agent_signature>, now() AS added_at
CREATE TABLE IF NOT EXISTS agent_sql_guide AS
SELECT 'crawl a tree and read every file' AS name, content AS sql, 'ls, prune folders in the WHERE, post one ls per kept folder to /sql, unnest the receipts; a CASE picks the reader per file and that is posted too. Statements are concatenated parts, one chr(39) pair each; receipts kept.' AS notes, 'claude_code-claude_opus_5_5' AS agent_signature, now() AS added_at
FROM read_text('/Users/aloksubbarao/duckdb-skills/skills/self-dispatch/references/declarative_ls.sql')
UNION ALL SELECT 'schedule a file so edits are live', content, 'each cron posts the current text of a file to /sql through post_file, so an edit changes the next run with no restart and no re-registration.', 'claude_code-claude_opus_5_5', now()
FROM read_text('/Users/aloksubbarao/duckdb-skills/server/cron.sql')
UNION ALL SELECT 'start your own server on a free port', content, 'lsof through shellfs gives the ports in use; the free ones are range() anti-joined with them; a :memory: DuckDB serves quack and /sql there; telemetry goes to dev with quack_query.', 'claude_code-claude_opus_5_5', now()
FROM read_text('/Users/aloksubbarao/duckdb-skills/skills/query-duckdb/own_server.sql');

-- hostfs_info(path): every hostfs path scalar as one struct; unnest() spreads it into columns.
-- ls([path VARCHAR [, BOOLEAN]]) -> path; path_split(path) is a hostfs macro; hsize(HUGEINT) formats a byte count.
CREATE OR REPLACE MACRO hostfs_info(path) AS {
    file_name: file_name(path), file_extension: file_extension(path), is_dir: is_dir(path), is_file: is_file(path),
    path_type: path_type(path), path_exists: path_exists(path), absolute_path: absolute_path(path),
    path_parts: path_split(path), file_size: file_size(path), hsize: hsize(file_size(path)),
    file_last_modified: file_last_modified(path)};
-- hostfs_ls: the working directory, one row per entry; agents.hostfs_ls(dir) is any one directory (the MCP tool).
CREATE OR REPLACE VIEW hostfs_ls AS SELECT unnest(hostfs_info(path)), * FROM ls();
CREATE OR REPLACE MACRO agents.hostfs_ls(root_path) AS TABLE SELECT unnest(hostfs_info(path)), * FROM ls(root_path);
-- hostfs_ls_2: one level down. Each non-dot folder of hostfs_ls becomes a `FROM ls('<dir>')` statement,
-- self-dispatched to this server's /sql (explicit LIMIT: /sql caps an unlimited SELECT at 20 rows).
-- http_post(url, headers MAP, body JSON [, params MAP]) -> JSON {status, reason, body}
CREATE OR REPLACE VIEW hostfs_ls_2 AS
    WITH post AS (
        SELECT absolute_path AS parent,
            ['FROM ls(', chr(39) || absolute_path || chr(39), ')', 'LIMIT 100000'] AS arr_path,
            array_to_string(arr_path, ' ') AS statement,
            http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', statement)) AS receipt
        FROM hostfs_ls
        WHERE is_dir AND NOT starts_with(file_name, '.')
    )
    SELECT unnest(hostfs_info(e.path)), e.path, parent, arr_path, statement, receipt ->> '$.status' AS status
    FROM post CROSS JOIN UNNEST(from_json(receipt ->> '$.body', '[{"path":"VARCHAR"}]')) AS u(e);

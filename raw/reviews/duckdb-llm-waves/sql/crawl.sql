-- ============================================================================
-- crawl.sql — crawling-incremental-ls: levels as PARTITIONS of node_map.
--   duckdb waves.duckdb -c "INSERT INTO crawls SELECT '/abs/root', now()::TIMESTAMP" -f sql/crawl.sql
-- ============================================================================
-- Every level ls's ONLY what the prior level admitted: prune junk BY NAME before
-- descending (lsr from the top is the banned move — it walks vendor trees before any
-- WHERE can filter them). No WITH RECURSIVE: the unrolled level chain IS the recursion.
--
-- ls(dir) is a table function and binds a literal, so the per-folder call is
-- SELF-DISPATCHED: the statement is built per frontier row and POSTed to a quackapi
-- route THIS process serves, whose handler is query($q). Rows come back as a JSON
-- array. No macros, no variables, no external server, no token: the executor is us.
-- ============================================================================
LOAD hostfs; LOAD http_client; LOAD quackapi;
CREATE OR REPLACE ROUTE dispatch POST '/q' AS SELECT rows.* FROM query($q) rows;
FROM quackapi_serve(19503, host := '127.0.0.1');

-- SEED (depth 1): the root is DATA — the latest crawls row — and becomes a literal
-- only inside the dispatched statement (chr(39) is the quote).
CREATE OR REPLACE TABLE node_map AS
WITH root  AS (SELECT root FROM crawls ORDER BY started_at DESC LIMIT 1),
fired AS (SELECT root, http_post_form('http://127.0.0.1:19503/q', MAP{},
                        MAP{'q': format('SELECT path FROM ls({}{}{})', chr(39), root, chr(39))}) AS r FROM root),
nodes AS (SELECT root, row.path AS path
          FROM fired, unnest(from_json((r.body ->> '$'), '[{"path":"VARCHAR"}]')) AS s(row)
          WHERE r.status = 200)
SELECT root, path, 1 AS depth, is_dir(path) AS is_dir_flag
FROM nodes
WHERE (is_dir(path) AND NOT starts_with(file_name(path), '.')
        AND file_name(path) NOT IN (SELECT name FROM policy_skip_dirs))
   OR (is_file(path) AND lower(file_extension(path)) IN (SELECT ext FROM policy_exts));

-- LEVELS 2..9: the same block, frontier = the prior committed partition. An empty
-- frontier costs zero dispatches, so levels past the tree's depth are free.
INSERT INTO node_map BY NAME
WITH frontier AS (SELECT root, path FROM node_map WHERE depth = 1 AND is_dir_flag),
fired AS (SELECT root, http_post_form('http://127.0.0.1:19503/q', MAP{},
                        MAP{'q': format('SELECT path FROM ls({}{}{})', chr(39), path, chr(39))}) AS r FROM frontier),
nodes AS (SELECT root, row.path AS path FROM fired, unnest(from_json((r.body ->> '$'), '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT root, path, 2 AS depth, is_dir(path) AS is_dir_flag FROM nodes
WHERE (is_dir(path) AND NOT starts_with(file_name(path), '.') AND file_name(path) NOT IN (SELECT name FROM policy_skip_dirs))
   OR (is_file(path) AND lower(file_extension(path)) IN (SELECT ext FROM policy_exts));

INSERT INTO node_map BY NAME
WITH frontier AS (SELECT root, path FROM node_map WHERE depth = 2 AND is_dir_flag),
fired AS (SELECT root, http_post_form('http://127.0.0.1:19503/q', MAP{},
                        MAP{'q': format('SELECT path FROM ls({}{}{})', chr(39), path, chr(39))}) AS r FROM frontier),
nodes AS (SELECT root, row.path AS path FROM fired, unnest(from_json((r.body ->> '$'), '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT root, path, 3 AS depth, is_dir(path) AS is_dir_flag FROM nodes
WHERE (is_dir(path) AND NOT starts_with(file_name(path), '.') AND file_name(path) NOT IN (SELECT name FROM policy_skip_dirs))
   OR (is_file(path) AND lower(file_extension(path)) IN (SELECT ext FROM policy_exts));

INSERT INTO node_map BY NAME
WITH frontier AS (SELECT root, path FROM node_map WHERE depth = 3 AND is_dir_flag),
fired AS (SELECT root, http_post_form('http://127.0.0.1:19503/q', MAP{},
                        MAP{'q': format('SELECT path FROM ls({}{}{})', chr(39), path, chr(39))}) AS r FROM frontier),
nodes AS (SELECT root, row.path AS path FROM fired, unnest(from_json((r.body ->> '$'), '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT root, path, 4 AS depth, is_dir(path) AS is_dir_flag FROM nodes
WHERE (is_dir(path) AND NOT starts_with(file_name(path), '.') AND file_name(path) NOT IN (SELECT name FROM policy_skip_dirs))
   OR (is_file(path) AND lower(file_extension(path)) IN (SELECT ext FROM policy_exts));

INSERT INTO node_map BY NAME
WITH frontier AS (SELECT root, path FROM node_map WHERE depth = 4 AND is_dir_flag),
fired AS (SELECT root, http_post_form('http://127.0.0.1:19503/q', MAP{},
                        MAP{'q': format('SELECT path FROM ls({}{}{})', chr(39), path, chr(39))}) AS r FROM frontier),
nodes AS (SELECT root, row.path AS path FROM fired, unnest(from_json((r.body ->> '$'), '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT root, path, 5 AS depth, is_dir(path) AS is_dir_flag FROM nodes
WHERE (is_dir(path) AND NOT starts_with(file_name(path), '.') AND file_name(path) NOT IN (SELECT name FROM policy_skip_dirs))
   OR (is_file(path) AND lower(file_extension(path)) IN (SELECT ext FROM policy_exts));

INSERT INTO node_map BY NAME
WITH frontier AS (SELECT root, path FROM node_map WHERE depth = 5 AND is_dir_flag),
fired AS (SELECT root, http_post_form('http://127.0.0.1:19503/q', MAP{},
                        MAP{'q': format('SELECT path FROM ls({}{}{})', chr(39), path, chr(39))}) AS r FROM frontier),
nodes AS (SELECT root, row.path AS path FROM fired, unnest(from_json((r.body ->> '$'), '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT root, path, 6 AS depth, is_dir(path) AS is_dir_flag FROM nodes
WHERE (is_dir(path) AND NOT starts_with(file_name(path), '.') AND file_name(path) NOT IN (SELECT name FROM policy_skip_dirs))
   OR (is_file(path) AND lower(file_extension(path)) IN (SELECT ext FROM policy_exts));

INSERT INTO node_map BY NAME
WITH frontier AS (SELECT root, path FROM node_map WHERE depth = 6 AND is_dir_flag),
fired AS (SELECT root, http_post_form('http://127.0.0.1:19503/q', MAP{},
                        MAP{'q': format('SELECT path FROM ls({}{}{})', chr(39), path, chr(39))}) AS r FROM frontier),
nodes AS (SELECT root, row.path AS path FROM fired, unnest(from_json((r.body ->> '$'), '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT root, path, 7 AS depth, is_dir(path) AS is_dir_flag FROM nodes
WHERE (is_dir(path) AND NOT starts_with(file_name(path), '.') AND file_name(path) NOT IN (SELECT name FROM policy_skip_dirs))
   OR (is_file(path) AND lower(file_extension(path)) IN (SELECT ext FROM policy_exts));

INSERT INTO node_map BY NAME
WITH frontier AS (SELECT root, path FROM node_map WHERE depth = 7 AND is_dir_flag),
fired AS (SELECT root, http_post_form('http://127.0.0.1:19503/q', MAP{},
                        MAP{'q': format('SELECT path FROM ls({}{}{})', chr(39), path, chr(39))}) AS r FROM frontier),
nodes AS (SELECT root, row.path AS path FROM fired, unnest(from_json((r.body ->> '$'), '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT root, path, 8 AS depth, is_dir(path) AS is_dir_flag FROM nodes
WHERE (is_dir(path) AND NOT starts_with(file_name(path), '.') AND file_name(path) NOT IN (SELECT name FROM policy_skip_dirs))
   OR (is_file(path) AND lower(file_extension(path)) IN (SELECT ext FROM policy_exts));

INSERT INTO node_map BY NAME
WITH frontier AS (SELECT root, path FROM node_map WHERE depth = 8 AND is_dir_flag),
fired AS (SELECT root, http_post_form('http://127.0.0.1:19503/q', MAP{},
                        MAP{'q': format('SELECT path FROM ls({}{}{})', chr(39), path, chr(39))}) AS r FROM frontier),
nodes AS (SELECT root, row.path AS path FROM fired, unnest(from_json((r.body ->> '$'), '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT root, path, 9 AS depth, is_dir(path) AS is_dir_flag FROM nodes
WHERE (is_dir(path) AND NOT starts_with(file_name(path), '.') AND file_name(path) NOT IN (SELECT name FROM policy_skip_dirs))
   OR (is_file(path) AND lower(file_extension(path)) IN (SELECT ext FROM policy_exts));

FROM quackapi_stop();

-- VALIDATION — folders + files MUST be > 0; a policy_skip_dirs name in the map is a leak.
SELECT count(*) FILTER (WHERE is_dir_flag)     AS folders,
       count(*) FILTER (WHERE NOT is_dir_flag) AS files,
       max(depth)                              AS depth,
       count(*) FILTER (WHERE is_dir_flag AND file_name(path) IN (SELECT name FROM policy_skip_dirs)) AS skip_dir_leaks
FROM node_map;

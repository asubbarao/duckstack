-- own_server.sql — an agent's OWN DuckDB server: a fresh :memory: process that picks two free
-- ports in SQL, serves quack + a quackapi /sql route on them, and reports itself to the shared
-- dev server. It never opens ~/.duck/dev.duckdb and never binds 9494/9495/9496.
--
-- Why not `.read server/setup.sql` with DEV_*_PORT overrides: setup.sql's own ports are
-- overridable, but the files it includes are not a second instance (see SKILL.md, "Why not
-- setup.sql"). This is the minimal subset of setup.sql sections 0, 1 and 5.
--
-- Start (from any DuckDB with shellfs; the process keeps stdin open through `tail -f /dev/null`):
--   FROM read_lines($c$QUACK_TOKEN=$(cat ~/.duck/token) nohup sh -c "tail -f /dev/null | /opt/homebrew/bin/duckdb :memory: -cmd '.read /Users/aloksubbarao/duckdb-skills/skills/query-duckdb/own_server.sql'" > /tmp/own_server.log 2>&1 & echo pid=$! |$c$);
-- Ports: the dev row agents.own_server_heartbeat, or /tmp/own_server.log (the _own_server row).
-- Stop:  FROM read_lines('pkill -TERM -P <pid>; echo exit=$? |');   -- <pid> is the sh from pid=

-- .bail on: the first failing statement ends the process instead of cascading NULL ports.
.bail on

-- getenv(name) -- only parameter. extension_directory default '~/.duckdb/extensions'; the shared
-- directory already holds every extension at this CLI's version, so no INSTALL downloads.
SET GLOBAL extension_directory = getenv('HOME') || '/.duck/extensions';

-- INSTALL <ext> [FROM repo] -- idempotent; LOAD <ext> -- each its own statement.
INSTALL quack; LOAD quack;
INSTALL shellfs FROM community; LOAD shellfs;
INSTALL read_lines FROM community; LOAD read_lines;   -- read_lines() is this extension, not core
INSTALL quackapi FROM community; LOAD quackapi;

-- read_lines(path, ...) -- a path ending in `|` is a shellfs command pipe. Columns: line_number,
--   content, file_path. string_split(s, sep) -> list; split_part(s, sep, index); try_cast(x AS T).
-- range(start, stop) -- stop exclusive. list_sort(list) ascending; [1:2] = the two lowest.
CREATE OR REPLACE TABLE _ports AS
WITH listen AS (
  SELECT content,
         try_cast(string_split(split_part(content, ' (LISTEN)', 1), ':')[-1] AS BIGINT) AS port
  FROM read_lines('lsof -nP -iTCP -sTCP:LISTEN |')
  WHERE line_number > 1
), free AS (
  FROM range(9497, 9600) r(port) ANTI JOIN listen USING (port)
)
SELECT list_sort(array_agg(port))[1:2] AS pair FROM free;

-- read_lines('echo $PPID |') -- the shell's parent is this duckdb process: its pid, for kill.
CREATE OR REPLACE TABLE _own_pid AS
SELECT content::BIGINT AS duckdb_pid FROM read_lines('echo $PPID |');

SET VARIABLE quack_uri     = (SELECT 'quack:localhost:' || pair[1] FROM _ports);
SET VARIABLE quackapi_port = (SELECT pair[2]::INTEGER FROM _ports);

-- quack_identify(name, hostname, region, provider, meta) -- all default NULL; read back with whoami().
CALL quack_identify(name := 'own-' || getvariable('quackapi_port'), hostname := 'localhost',
                    region := 'local', provider := 'local', meta := '{"role": "agent-own-duckdb"}');

-- quack_serve(uri, token := NULL, allow_other_hostname := false, disable_ssl := false)
--   token min 4 chars; the same ~/.duck/token the launch command exports.
CREATE OR REPLACE TABLE _quack_serve AS
SELECT now() AS started_at, listen_uri, listen_url
FROM quack_serve(getvariable('quack_uri'), token := getenv('QUACK_TOKEN'));

-- quack_query(uri, sql, disable_ssl := false, token := NULL) -- runs a complete body on that
-- server. The route text needs this instance's quack URI as a literal, so it is rendered here and
-- run through the instance's own quack door (the same move as server/quackapi.sql).
--   CREATE ROUTE name POST '/path' AS <select>; $sql binds the JSON body field "sql".
FROM quack_query(getvariable('quack_uri'),
  replace($routes$
CREATE OR REPLACE ROUTE sql POST '/sql'
  AS SELECT * FROM quack_query('@QUACK_URI', $sql, token := getenv('QUACK_TOKEN'));
$routes$, '@QUACK_URI', getvariable('quack_uri')),
  token := getenv('QUACK_TOKEN'));

-- quackapi_serve(port, health_routes, static_dir, keep_alive_timeout_sec, host, cors_origins,
--   http_client, memory_limit, log_level, enable_logging, enable_http_metadata_cache, access_log,
--   read_timeout_sec, threads, preserve_insertion_order, query_timeout_ms, worker_threads,
--   compression, compression_min_bytes, pg_dsn, write_timeout_sec, block, max_response_bytes,
--   keep_alive_max_count, max_pending_requests). Defaults it prints at start: enable_logging=false,
--   access_log=true, worker_threads=32, read/write timeouts 30 s, 8 MiB body cap,
--   preserve_insertion_order=false (process-wide). host '127.0.0.1': local only.
CREATE OR REPLACE TABLE _quackapi_serve AS
SELECT now() AS started_at, * FROM quackapi_serve(getvariable('quackapi_port'), host := '127.0.0.1');

CREATE OR REPLACE TABLE _own_server AS
SELECT now() AS started_at, p.duckdb_pid, q.listen_uri AS quack_uri,
       'http://127.0.0.1:' || getvariable('quackapi_port') || '/sql' AS sql_url
FROM _own_pid p CROSS JOIN _quack_serve q;
FROM _own_server;

-- Telemetry: one row to the shared dev server over its quack door (quack:localhost:9494).
-- quack_query takes only constants ("Table function cannot contain subqueries"), so the row's
-- values are written into a statement and self-dispatched through this instance's own /sql,
-- which also proves the route end to end. The receipt is kept.
--   printf(fmt, args...); http_post(url, headers MAP, body JSON) -> JSON {status, reason, body}.
INSTALL http_client FROM community; LOAD http_client;
CREATE OR REPLACE TABLE _heartbeat AS
SELECT statement, http_post(sql_url, MAP {'Content-Type': 'application/json'},
                            json_object('sql', statement)) AS receipt
FROM (SELECT sql_url, printf($s$FROM quack_query('quack:localhost:9494', $hb$
CREATE TABLE IF NOT EXISTS agents.own_server_heartbeat
  (sent_at TIMESTAMPTZ, duckdb_pid BIGINT, quack_uri VARCHAR, sql_url VARCHAR, duckdb_version VARCHAR);
INSERT INTO agents.own_server_heartbeat BY NAME
SELECT now() AS sent_at, %d AS duckdb_pid, '%s' AS quack_uri, '%s' AS sql_url, '%s' AS duckdb_version
$hb$, token := getenv('QUACK_TOKEN'))$s$, duckdb_pid, quack_uri, sql_url, version()) AS statement
      FROM _own_server);
SELECT receipt->>'status' AS status, receipt->>'body' AS body FROM _heartbeat;

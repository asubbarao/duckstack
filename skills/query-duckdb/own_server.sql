-- own_server.sql — an agent's OWN disposable DuckDB: a fresh :memory: process that picks three
-- free ports in SQL and serves quack, QuackAPI /sql and duckdb_mcp. It has no dependency on dev,
-- never opens ~/.duck/dev.duckdb and never binds 9494/9495/9496.
--
-- Why not `.read server/setup.sql` with DEV_*_PORT overrides: setup.sql's own ports are
-- overridable, but the files it includes are not a second instance (see SKILL.md, "Why not
-- setup.sql"). This is the minimal subset of setup.sql sections 0, 1 and 5.
--
-- Start (from any DuckDB with shellfs; the process keeps stdin open through `tail -f /dev/null`):
--   FROM read_lines($c$QUACK_TOKEN=$(cat ~/.duck/token) nohup sh -c "tail -f /dev/null | /opt/homebrew/bin/duckdb :memory: -cmd '.read /Users/aloksubbarao/duckdb-skills/skills/query-duckdb/own_server.sql'" > /tmp/own_server.log 2>&1 & echo pid=$! |$c$);
-- Ports: /tmp/own_server.log (the _own_server row). A free-port probe is optimistic; if another
-- process wins the bind race, .bail stops startup and the launcher should rerun this file.
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
INSTALL http_client FROM community; LOAD http_client;
INSTALL parser_tools FROM community; LOAD parser_tools;
INSTALL duckdb_mcp FROM community; LOAD duckdb_mcp;

-- read_lines(path, ...) -- a path ending in `|` is a shellfs command pipe. Columns: line_number,
--   content, file_path. string_split(s, sep) -> list; split_part(s, sep, index); try_cast(x AS T).
-- range(start, stop) -- stop exclusive. list_sort(list) ascending; [1:3] = the three lowest.
CREATE OR REPLACE TABLE _ports AS
WITH listen AS (
  SELECT content,
         try_cast(string_split(split_part(content, ' (LISTEN)', 1), ':')[-1] AS BIGINT) AS port
  FROM read_lines('lsof -nP -iTCP -sTCP:LISTEN |')
  WHERE line_number > 1
), free AS (
  FROM range(9497, 9600) r(port) ANTI JOIN listen USING (port)
)
SELECT list_sort(array_agg(port))[1:3] AS ports FROM free;

-- read_lines('echo $PPID |') -- the shell's parent is this duckdb process: its pid, for kill.
CREATE OR REPLACE TABLE _own_pid AS
SELECT content::BIGINT AS duckdb_pid FROM read_lines('echo $PPID |');

SET VARIABLE quack_uri     = (SELECT 'quack:localhost:' || ports[1] FROM _ports);
SET VARIABLE quackapi_port = (SELECT ports[2]::INTEGER FROM _ports);
SET VARIABLE mcp_port      = (SELECT ports[3]::INTEGER FROM _ports);

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
SELECT uuid()::VARCHAR AS instance_id, now() AS started_at, p.duckdb_pid,
       q.listen_uri AS quack_uri,
       'http://127.0.0.1:' || getvariable('quackapi_port') || '/sql' AS sql_url,
       'http://127.0.0.1:' || getvariable('mcp_port') || '/mcp' AS mcp_url
FROM _own_pid p CROSS JOIN _quack_serve q;

-- Wire mechanic: fresh MCP connections resolve this instance's endpoint from its catalog.
-- Source rows never bind to a table function laterally; they render complete statements first.
CREATE OR REPLACE MACRO own_sql_url() AS (SELECT sql_url FROM _own_server);

-- MCP tools discover this process's QuackAPI listener from quackapi_servers(), so the same SQL
-- works on any selected ports and every fresh MCP connection targets this instance, never dev.
PRAGMA mcp_publish_tool('runtime',
  'Identify this disposable agent-owned DuckDB and its selected Quack, SQL and MCP endpoints.',
  'SELECT *, version() AS engine_version FROM _own_server', '{}', '[]', 'json');
PRAGMA mcp_publish_tool('query_with_limit',
  'Run a complete SQL program on this agent-owned DuckDB. A final SELECT without its own LIMIT is capped at 20 rows; writes are not capped. Returns the raw HTTP receipt.',
  $forward$WITH submitted AS (
    SELECT own_sql_url() AS sql_url, $sql AS submitted_sql, uuid()::VARCHAR AS request_id
  ), parsed AS (
    SELECT *, try(parse_statements(submitted_sql)) AS statements FROM submitted
  ), classified AS (
    SELECT *, statements[-1] AS final_sql, json_serialize_sql(final_sql) AS ast FROM parsed
  ), prepared AS (
    SELECT *, coalesce(ast->>'error' = 'false'
      AND len(list_filter(json_extract(ast, '$.statements[0].node.modifiers[*].limit'), x -> x <> 'null'::JSON)) = 0, false) AS default_limit_applied,
      CASE WHEN default_limit_applied
        THEN array_to_string(list_concat(statements[:-2], [printf('SELECT * FROM (%s) AS agent_result LIMIT 20', final_sql)]), ';' || chr(10))
        ELSE submitted_sql END AS executed_sql
    FROM classified
  )
  SELECT request_id, submitted_sql, executed_sql, default_limit_applied,
         http_post(sql_url, MAP{'Content-Type':'application/json'},
                   json_object('sql', executed_sql)) AS response
  FROM prepared$forward$,
  '{"sql":{"type":"string","description":"Complete SQL program"}}', '["sql"]', 'json');
PRAGMA mcp_publish_tool('query_no_limit',
  'Run SQL on this agent-owned DuckDB exactly as written. Use only when the result is known to be small or for writes. Never replay an uncertain write.',
  $forward$SELECT $sql AS submitted_sql,
    http_post(own_sql_url(), MAP{'Content-Type':'application/json'},
              json_object('sql', '/* no_limit=true */' || chr(10) || $sql)) AS response$forward$,
  '{"sql":{"type":"string","description":"Complete SQL program, sent without a row cap"}}',
  '["sql"]', 'json');
PRAGMA mcp_publish_tool('self_dispatch',
  'Execute one generated statement per source row through this instance. Keep batches bounded; returns source rows, statements and raw receipts, including failures.',
  $dispatch$WITH statements AS (
    FROM query($rows_sql)
  ), posted AS (
    SELECT array_agg({source: statements, response:
      http_post(own_sql_url(), MAP{'Content-Type':'application/json'}, json_object('sql', statement))}) AS receipts
    FROM statements
  )
  SELECT receipt.source AS source, receipt.source.statement AS statement,
         receipt.response.status AS status, receipt.response.body AS body,
         receipt.response AS response
  FROM posted CROSS JOIN UNNEST(receipts) AS t(receipt)$dispatch$,
  '{"rows_sql":{"type":"string","description":"SELECT ... AS statement FROM ..."}}',
  '["rows_sql"]', 'json');
PRAGMA mcp_server_start('http', '127.0.0.1', getvariable('mcp_port'),
  '{"builtin_tools": false, "background": true, "default_result_format": "markdown"}');

FROM _own_server;

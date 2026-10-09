-- An agent's own disposable DuckDB: a fresh :memory: process with the same three doors as dev on
-- other ports (9504 quack, 9505 /sql, 9506 MCP). It never opens ~/.duck/dev.duckdb.
--
-- Start, from any DuckDB with shellfs (the process keeps stdin open through `tail -f /dev/null`):
--   FROM read_lines($c$QUACK_TOKEN=$(cat ~/.duck/token) nohup sh -c "tail -f /dev/null | /opt/homebrew/bin/duckdb :memory: -cmd '.read /Users/aloksubbarao/duckdb-skills/skills/query-duckdb/own_server.sql'" > /tmp/own_server.log 2>&1 & echo pid=$! |$c$);
-- A port already in use fails the bind, .bail stops the process and /tmp/own_server.log says which.
-- Stop:  FROM read_lines('pkill -TERM -P <pid>; echo exit=$? |');   -- <pid> is the sh from pid=
.bail on
SET GLOBAL extension_directory = getenv('HOME') || '/.duck/extensions';

INSTALL quack; LOAD quack;
INSTALL shellfs FROM community; LOAD shellfs;
INSTALL read_lines FROM community; LOAD read_lines;
INSTALL http_client FROM community; LOAD http_client;
INSTALL quackapi FROM community; LOAD quackapi;
INSTALL duckdb_mcp FROM community; LOAD duckdb_mcp;

CALL quack_identify(name := 'own-9504', hostname := 'localhost', region := 'local', provider := 'local', meta := '{"role": "agent-own-duckdb"}');
FROM quack_serve('quack:localhost:9504', token := getenv('QUACK_TOKEN'));
PRAGMA mcp_server_start('http', '127.0.0.1', 9506, '{"builtin_tools": true, "enable_execute_tool": true, "execute_allow_ddl": true, "execute_allow_dml": true, "execute_allow_load": true, "execute_allow_attach": true, "execute_allow_set": true, "background": true}');

CREATE OR REPLACE ROUTE sql POST '/sql' AS SELECT * FROM quack_query('quack:localhost:9504', $sql, token := getenv('QUACK_TOKEN'));
FROM quackapi_serve(9505, host := '127.0.0.1');

SELECT 'quack:localhost:9504' AS quack_uri, 'http://127.0.0.1:9505/sql' AS sql_url, 'http://127.0.0.1:9506/mcp' AS mcp_url;

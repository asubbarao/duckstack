-- Dev DuckDB. launchd runs `duckdb -bail ~/.duck/dev.duckdb -init setup.sql` and keeps stdin open.
-- Dev boots ~/.duck/deploy/server/setup.sql, the duckdb-skills branch `deploy`. A save here changes nothing until
-- it is committed and the branch moved: git branch -f deploy <commit>; the watcher restarts dev within 30 s.
SET GLOBAL extension_directory = '/Users/aloksubbarao/.duck/extensions';
SET GLOBAL secret_directory = '/Users/aloksubbarao/.duck/secrets';
SET GLOBAL temp_directory = '/Users/aloksubbarao/.duck/tmp';
SET GLOBAL memory_limit = '8GB';
SET GLOBAL threads = 10;
SET GLOBAL TimeZone = 'UTC';
SET GLOBAL http_retries = 0;

INSTALL quack; LOAD quack;
INSTALL httpfs; LOAD httpfs;
INSTALL ducklake; LOAD ducklake;
INSTALL cronjob FROM community; LOAD cronjob;
INSTALL shellfs FROM community; LOAD shellfs;
INSTALL hostfs FROM community; LOAD hostfs;
INSTALL http_client FROM community; LOAD http_client;
INSTALL read_lines FROM community; LOAD read_lines;
INSTALL agent_data FROM community; LOAD agent_data;
INSTALL quackapi FROM community; LOAD quackapi;
INSTALL duckdb_mcp FROM community; LOAD duckdb_mcp;
-- Used by the agents.ext_* docs views, otlp_events and meta.prometheus_metrics.
INSTALL webbed FROM community; LOAD webbed;
INSTALL markdown FROM community; LOAD markdown;
INSTALL urlpattern FROM community; LOAD urlpattern;
INSTALL otlp FROM community; LOAD otlp;
INSTALL sazgar FROM community; LOAD sazgar;
-- Called by name from the skills (tera, duck-tails, duck-hunt, pdf-digest, ci-timing, ...).
INSTALL tera FROM community; LOAD tera;
INSTALL parser_tools FROM community; LOAD parser_tools;
INSTALL sitting_duck FROM community; LOAD sitting_duck;
INSTALL duck_tails FROM community; LOAD duck_tails;
INSTALL duck_hunt FROM community; LOAD duck_hunt;
INSTALL zipfs FROM community; LOAD zipfs;
INSTALL scalarfs FROM community; LOAD scalarfs;
INSTALL yaml FROM community; LOAD yaml;
INSTALL pdf FROM community; LOAD pdf;
INSTALL gh FROM community; LOAD gh;
INSTALL netquack FROM community; LOAD netquack;
INSTALL fts; LOAD fts;

ATTACH IF NOT EXISTS 'ducklake:/Users/aloksubbarao/.duck/lake/duckstack/catalog.ducklake' AS lake
    (DATA_PATH '/Users/aloksubbarao/.duck/lake/duckstack/data/', DATA_INLINING_ROW_LIMIT 0);

CALL enable_logging(['QueryLog', 'HTTP', 'Quack'], storage := 'file', storage_path := getenv('QUACK_NATIVE_LOG'), storage_buffer_size := 0);
SELECT cron('CHECKPOINT', '45 */5 * * * *');

CREATE SCHEMA IF NOT EXISTS agent;
CREATE OR REPLACE VIEW agent.stream AS
SELECT * REPLACE ('claude' AS source) FROM read_conversations(source := 'claude', path := '/Users/aloksubbarao/.claude')
UNION ALL BY NAME
SELECT * REPLACE ('claude-desktop' AS source) FROM read_conversations(source := 'claude-desktop', path := '/Users/aloksubbarao/Library/Application Support/Claude')
UNION ALL BY NAME
SELECT * REPLACE ('codex' AS source) FROM read_conversations(source := 'codex', path := '/Users/aloksubbarao/.codex');

-- 9494 Quack. 9496 MCP with duckdb_mcp's own tools, execute included. 4318 OTLP/HTTP into the otlp_* tables.
FROM quack_serve('quack:localhost:9494', token := getenv('QUACK_TOKEN'));
PRAGMA mcp_server_start('http', '127.0.0.1', 9496, '{"builtin_tools": true, "enable_execute_tool": true, "execute_allow_ddl": true, "execute_allow_dml": true, "execute_allow_load": true, "execute_allow_attach": true, "execute_allow_set": true, "background": true}');
FROM otlp_serve('otlp:127.0.0.1:4318', disable_auth := true);

-- 9495: POST /sql {"sql": "..."}; POST /inbox any JSON, read it from quackapi_jobs; GET /metrics for Prometheus (/opt/homebrew/etc/prometheus.yml).
CREATE QUEUE inbox;
CREATE OR REPLACE ROUTE sql POST '/sql' AS SELECT * FROM quack_query('quack:localhost:9494', $sql, token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE ROUTE inbox POST '/inbox' STATUS 201 AS SELECT quackapi_enqueue('inbox', $body::JSON) AS id;
CREATE OR REPLACE ROUTE metrics GET '/metrics' AS SELECT text FROM meta.prometheus_metrics;
FROM quackapi_serve(9495, host := '127.0.0.1');
-- quackapi_serve switches logging off.
CALL enable_logging(['QueryLog', 'HTTP', 'Quack'], storage := 'file', storage_path := getenv('QUACK_NATIVE_LOG'), storage_buffer_size := 0);

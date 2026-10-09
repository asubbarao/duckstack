-- Dev DuckDB. launchd runs `duckdb -bail ~/.duck/dev.duckdb -init setup.sql` and keeps stdin open.
-- Ports: 9494 quack, 9495 /sql (POST {"sql": "..."}), 9496 MCP.
SET GLOBAL extension_directory = '~/.duck/extensions';
SET GLOBAL secret_directory = '~/.duck/secrets';
SET GLOBAL temp_directory = '~/.duck/tmp';
SET GLOBAL memory_limit = '8GB';
SET GLOBAL threads = 10;
SET GLOBAL TimeZone = 'UTC';
SET GLOBAL http_retries = 0;

INSTALL quack; LOAD quack;
INSTALL httpfs; LOAD httpfs;
INSTALL ducklake; LOAD ducklake;
INSTALL cronjob FROM community; LOAD cronjob;
INSTALL shellfs FROM community; LOAD shellfs;
INSTALL http_client FROM community; LOAD http_client;
INSTALL read_lines FROM community; LOAD read_lines;
INSTALL agent_data FROM community; LOAD agent_data;
INSTALL quackapi FROM community; LOAD quackapi;
INSTALL duckdb_mcp FROM community; LOAD duckdb_mcp;

CREATE TEMPORARY SECRET github_http (TYPE HTTP, BEARER_TOKEN nullif(getenv('GITHUB_TOKEN'), ''), SCOPE 'https://api.github.com');
CREATE TEMPORARY SECRET sentry_http (TYPE HTTP, BEARER_TOKEN nullif(getenv('SENTRY_AUTH_TOKEN'), ''), SCOPE 'https://us.sentry.io');
CREATE TEMPORARY SECRET slack_http (TYPE HTTP, BEARER_TOKEN nullif(getenv('SLACK_TOKEN'), ''), SCOPE 'https://slack.com');
CREATE TEMPORARY SECRET linear_http (TYPE HTTP, BEARER_TOKEN nullif(getenv('LINEAR_API_KEY'), ''), SCOPE 'https://api.linear.app');

ATTACH IF NOT EXISTS 'ducklake:~/.duck/lake/duckstack/catalog.ducklake' AS lake
    (DATA_PATH '~/.duck/lake/duckstack/data/', DATA_INLINING_ROW_LIMIT 0);

CALL enable_logging(['QueryLog', 'HTTP', 'Quack'], storage := 'file', storage_path := '~/.duck/logs/duckdb_log.csv', storage_buffer_size := 0);
SELECT cron('CHECKPOINT', '45 */5 * * * *');

CREATE SCHEMA IF NOT EXISTS agent;
CREATE OR REPLACE VIEW agent.stream AS
SELECT * REPLACE ('claude' AS source) FROM read_conversations(source := 'claude', path := '~/.claude')
UNION ALL BY NAME
SELECT * REPLACE ('claude-desktop' AS source) FROM read_conversations(source := 'claude-desktop', path := '~/Library/Application Support/Claude')
UNION ALL BY NAME
SELECT * REPLACE ('codex' AS source) FROM read_conversations(source := 'codex', path := '~/.codex');

FROM quack_serve('quack:localhost:9494', token := getenv('QUACK_TOKEN'));
PRAGMA mcp_server_start('http', '127.0.0.1', 9496, '{"builtin_tools": true, "enable_execute_tool": true, "execute_allow_ddl": true, "execute_allow_dml": true, "execute_allow_load": true, "execute_allow_attach": true, "execute_allow_set": true, "background": true}');

CREATE OR REPLACE ROUTE sql POST '/sql' AS SELECT * FROM quack_query('quack:localhost:9494', $sql, token := getenv('QUACK_TOKEN'));
FROM quackapi_serve(9495, host := '127.0.0.1');
-- quackapi_serve switches logging off.
CALL enable_logging(['QueryLog', 'HTTP', 'Quack'], storage := 'file', storage_path := '~/.duck/logs/duckdb_log.csv', storage_buffer_size := 0);

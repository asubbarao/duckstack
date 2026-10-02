-- setup.sql: the dev DuckDB. launchd runs `duckdb ~/.duck/dev.duckdb -init setup.sql`; a second instance is the same
-- file with DEV_QUACK_PORT / DEV_QUACKAPI_PORT / DEV_MCP_PORT set. Idempotent definitions live in live.sql,
-- schedules in cron.sql. Order matters: secrets settings precede every LOAD; the lock is last.
SET GLOBAL home_directory = getenv('HOME');
SET GLOBAL extension_directory = getenv('HOME') || '/.duck/extensions';
SET GLOBAL secret_directory = getenv('HOME') || '/.duck/secrets';

INSTALL quack; LOAD quack; INSTALL httpfs; LOAD httpfs; INSTALL aws; LOAD aws; INSTALL encodings; INSTALL ducklake;
.read /Users/aloksubbarao/duckdb-skills/server/api_secrets.sql
LOAD json; LOAD icu; LOAD parquet; INSTALL fts; LOAD fts; INSTALL postgres; LOAD postgres; INSTALL sqlite; LOAD sqlite;
INSTALL webbed FROM community; LOAD webbed; INSTALL markdown FROM community; LOAD markdown;
INSTALL crawler FROM community; LOAD crawler; INSTALL cronjob FROM community; LOAD cronjob;
INSTALL splink_udfs FROM community; LOAD splink_udfs; INSTALL urlpattern FROM community; LOAD urlpattern;
INSTALL netquack FROM community; LOAD netquack; INSTALL shellfs FROM community; LOAD shellfs;
INSTALL tera FROM community; LOAD tera; INSTALL scalarfs FROM community; LOAD scalarfs;
INSTALL http_client FROM community; LOAD http_client; INSTALL otlp FROM community; LOAD otlp;
INSTALL prometheus FROM community; LOAD prometheus; INSTALL cloudwatch FROM community; LOAD cloudwatch;
INSTALL quack_flamegraph FROM community; LOAD quack_flamegraph; INSTALL observefs FROM community; LOAD observefs;
INSTALL agent_data FROM community; LOAD agent_data; INSTALL duck_tails FROM community; LOAD duck_tails;
INSTALL duck_hunt FROM community; LOAD duck_hunt; INSTALL zipfs FROM community; LOAD zipfs;
INSTALL quickjs FROM community; LOAD quickjs; INSTALL miniplot FROM community; LOAD miniplot;
INSTALL minijinja FROM community; LOAD minijinja; INSTALL gh FROM community; LOAD gh;
INSTALL hostfs FROM community; LOAD hostfs; INSTALL pdf FROM community; LOAD pdf;
INSTALL parser_tools FROM community; LOAD parser_tools; INSTALL yaml FROM community; LOAD yaml;
INSTALL jsonata FROM community; LOAD jsonata; INSTALL sitting_duck FROM community; LOAD sitting_duck; INSTALL curl_httpfs FROM community; LOAD curl_httpfs;
.read /Users/aloksubbarao/duckdb-skills/server/live.sql

-- A laptop tenant: leave memory and cores for the desktop; bounded temp; UTC; patient HTTP; fewer checkpoint pauses.
SET GLOBAL memory_limit = '8GB'; SET GLOBAL threads = 10; SET GLOBAL scheduler_process_partial = true;
SET GLOBAL allocator_background_threads = true; SET GLOBAL temp_directory = getenv('HOME') || '/.duck/tmp';
SET GLOBAL max_temp_directory_size = '50GiB'; SET GLOBAL TimeZone = 'UTC'; SET GLOBAL checkpoint_threshold = '128MiB';
SET GLOBAL http_timeout = 120; SET GLOBAL http_retries = 5; SET GLOBAL http_retry_wait_ms = 500;
SET GLOBAL httpfs_connection_caching = true; SET enable_progress_bar = false; PRAGMA enable_checkpoint_on_shutdown;
-- No query may trigger a silent download; profiling stays settable after the lock; no Hugging Face reads.
SET GLOBAL autoinstall_known_extensions = false; SET GLOBAL allowed_configs = ['enable_profiling', 'profiling_coverage'];
SET GLOBAL disabled_filesystems = 'HuggingFaceFileSystem';

-- Every query on this instance, to one CSV. quackapi_serve switches logging off, so it is applied again after serving.
-- enable_logging(types, level, storage, storage_config, storage_path, storage_normalize, storage_buffer_size)
.read /Users/aloksubbarao/duckdb-skills/server/server_instance.sql
SET VARIABLE log_path = coalesce(nullif(getenv('QUACK_NATIVE_LOG'), ''), getenv('HOME') || '/.duck/logs/duckdb_log.csv');
CALL enable_logging(['QueryLog', 'HTTP', 'Quack', 'Metrics'], storage := 'file', storage_path := getvariable('log_path'), storage_buffer_size := 0);
CREATE OR REPLACE VIEW query_log AS SELECT * EXCLUDE (type, message), message AS query FROM duckdb_logs WHERE type = 'QueryLog';
CREATE OR REPLACE VIEW http_log AS FROM duckdb_logs_parsed('HTTP');
CREATE OR REPLACE VIEW quack_log AS FROM duckdb_logs_parsed('Quack');
CREATE OR REPLACE VIEW metrics_log AS FROM duckdb_logs_parsed('Metrics');

-- Serve: quack (token from the environment; unset fails closed), quackapi /sql + OTLP routes, the dev MCP.
SET VARIABLE quack_uri = 'quack:localhost:' || coalesce(nullif(getenv('DEV_QUACK_PORT'), ''), '9494');
SET VARIABLE quackapi_port = coalesce(nullif(getenv('DEV_QUACKAPI_PORT'), ''), '9495')::INTEGER;
SET VARIABLE mcp_port = coalesce(nullif(getenv('DEV_MCP_PORT'), ''), '9496')::INTEGER;
SET VARIABLE otlp_dir = getenv('HOME') || '/.duck/otlp';
CALL quack_identify(name := 'dev', hostname := 'localhost', region := 'local', provider := 'local', meta := '{"role": "dev-duckdb"}');
CREATE OR REPLACE TABLE _quack_serve AS SELECT now() AS started_at, listen_uri, listen_url FROM quack_serve(getvariable('quack_uri'), token := getenv('QUACK_TOKEN'));
.read /Users/aloksubbarao/duckdb-skills/server/quackapi.sql
.read /Users/aloksubbarao/duckdb-skills/server/telemetry.sql
CREATE OR REPLACE TABLE _listeners AS SELECT now() AS at, 'quack' AS service, listen_uri AS address FROM quack_server_list()
    UNION ALL SELECT now(), 'quackapi', listen_url FROM quackapi_servers()
    UNION ALL SELECT now(), 'mcp', 'http://localhost:' || getvariable('mcp_port') || '/mcp';
INSERT OR REPLACE INTO meta.runtime_endpoints (service, address, recorded_at)
SELECT service, address, "at" FROM _listeners;
.read /Users/aloksubbarao/duckdb-skills/server/duckdb_mcp.sql
CALL enable_logging(['QueryLog', 'HTTP', 'Quack', 'Metrics'], storage := 'file', storage_path := getvariable('log_path'), storage_buffer_size := 0);

.read /Users/aloksubbarao/duckdb-skills/server/observability.sql
.read /Users/aloksubbarao/duckdb-skills/server/query_history.sql
.read /Users/aloksubbarao/duckdb-skills/server/server_diagnostics.sql
.read /Users/aloksubbarao/duckdb-skills/server/cron.sql

-- The effective configuration, every start; then refuse to serve a crippled or over-permissive instance.
CREATE OR REPLACE TABLE _setup_settings AS SELECT now() AS recorded_at, * FROM duckdb_settings();
CREATE TABLE IF NOT EXISTS _setup_settings_history AS FROM _setup_settings LIMIT 0;
INSERT INTO _setup_settings_history BY NAME FROM _setup_settings;
SELECT error('setup.sql: refusing to serve -- ' || name || ' = ' || value) FROM duckdb_settings()
WHERE name || '=' || value IN ('allow_community_extensions=false', 'enable_external_access=false',
    'allow_unsigned_extensions=true', 'allow_unredacted_secrets=true');
-- After this no connection can SET/PRAGMA/RESET; INSTALL, LOAD, ATTACH and HTTP still work.
SET GLOBAL lock_configuration = true;

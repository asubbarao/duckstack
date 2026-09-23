-- ============================================================================
-- setup.sql — the one persistent dev DuckDB on this machine, served over quack.
--
-- Runs under launchd (com.inframe.quack) as:
--   tail -f /dev/null | duckdb ~/.duck/dev.duckdb -init ~/.duck/setup.sql
-- The file is held locked by this process for as long as the Mac is on. Nobody
-- opens it directly (even -readonly is refused). Every agent and every human reaches it
-- through one of the listeners section 5 starts, all in this process:
--   the `dev` MCP (query / sql tools), POST <quackapi>/sql, or from a :memory: client
--   LOAD quack; FROM quack_query('quack:localhost:<port>', $$…$$, token := getenv('QUACK_TOKEN'));
-- The ports are in _ports (defaults below, DEV_<SERVICE>_PORT overrides).
--
-- Verified on DuckDB v1.5.5 (d8cdaa33fd) osx_arm64; quack c154811 (beta — re-verify
-- on upgrade). An error anywhere in this file makes the CLI exit and launchd
-- restart it, so every statement here has been run clean on a fresh and on an
-- existing database. Statement ORDER is load-bearing; each section says why.
--
-- Scope rule behind every SET: GLOBAL settings live on the instance and reach the
-- connections quack opens per client; LOCAL ones reach only this init connection
-- and are therefore (almost) not set here. The engine rejects a cross-scope SET
-- loudly ("cannot be set globally"), so a scope mistake fails at start, not silently.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Paths. launchd starts with a minimal environment; pin the home first.
-- ---------------------------------------------------------------------------
-- home_directory        default '' (GLOBAL): `~` expansion needs it.
-- getenv(name) -- only parameter, no defaults. Works in a SET value position.
SET GLOBAL home_directory = getenv('HOME');

-- extension_directory   default '' -> ~/.duckdb/extensions (GLOBAL). The server gets
-- its own directory so an ad-hoc `duckdb` in a terminal can never swap a binary
-- underneath a running process. Must precede every INSTALL below.
SET GLOBAL extension_directory = getenv('HOME') || '/.duck/extensions';

-- Secret storage must be decided before ANY extension loads: LOAD httpfs/aws initialises the
-- secret manager, after which 1.5.5 refuses these with "Changing Secret Manager settings
-- after the secret manager is used is not allowed!" (verified -- it aborted this file).
-- allow_persistent_secrets   default true. Credentials are CREATE PERSISTENT SECRET, never in
--                            this file; they reload from secret_directory on every start.
SET GLOBAL allow_persistent_secrets = true;
-- secret_directory           default ~/.duckdb/stored_secrets. Files are 0600; the directory is
--                            made 0700 by the launchd wrapper.
SET GLOBAL secret_directory = getenv('HOME') || '/.duck/secrets';

-- ---------------------------------------------------------------------------
-- 1. Extensions. INSTALL is idempotent (no download once present). Nothing is
--    ever auto-installed (see 3), so everything the server may need is named here.
-- ---------------------------------------------------------------------------
INSTALL quack;       LOAD quack;       -- the door in; Quack log type registers on LOAD
INSTALL httpfs;      LOAD httpfs;      -- http(s):// + s3://; owns the http_* settings
INSTALL aws;         LOAD aws;         -- credential chain for s3 secrets
INSTALL encodings;                     -- non-UTF8 CSV; loads on demand
INSTALL ducklake;                      -- lakehouse catalog; ATTACH on demand
LOAD json; LOAD icu; LOAD parquet;     -- built in; stated

INSTALL webbed     FROM community; LOAD webbed;     -- HTML type + html_* on columns
INSTALL markdown   FROM community; LOAD markdown;   -- MARKDOWN type + md_*
INSTALL crawler    FROM community; LOAD crawler;    -- crawl(), crawl_url(); after webbed (read_html overloads coexist by arity)
INSTALL cronjob    FROM community; LOAD cronjob;    -- cron(), cron_jobs(), cron_delete()
INSTALL splink_udfs FROM community; LOAD splink_udfs; -- ngrams(): the direct-match grams in agent_stream_search.sql
INSTALL urlpattern FROM community; LOAD urlpattern; -- urlpattern_exec/extract, url_parse
INSTALL netquack   FROM community; LOAD netquack;   -- extract_domain/path/..., normalize_url
INSTALL shellfs    FROM community; LOAD shellfs;    -- read_csv('cmd |'): fetch through gh/curl inside SQL. Loaded on purpose: anyone holding the token can run shell here; accepted 2026-09-22.
INSTALL tera       FROM community; LOAD tera;       -- tera_render(template, ctx JSON): pages and SQL rendered from data
INSTALL scalarfs   FROM community; LOAD scalarfs;   -- variable:, data+varchar:, pathvariable: — values as files (section 5 reads its ports this way)
INSTALL http_client FROM community; LOAD http_client; -- http_post_form: self-dispatch posts to this process's own /sql

-- Observability/query-lab primitives available to every Quack client. OTLP arrives through
-- quackapi's /v1/* routes (section 5) as raw files; the otlp_* views read them with read_otlp_*;
-- Prometheus and CloudWatch query their own APIs; flamegraph reads folded profiles; the
-- condition cache is loaded but not enabled globally without a measured repeated workload.
INSTALL otlp                  FROM community; LOAD otlp;
INSTALL prometheus            FROM community; LOAD prometheus;
INSTALL cloudwatch            FROM community; LOAD cloudwatch;
INSTALL quack_flamegraph      FROM community; LOAD quack_flamegraph;
INSTALL query_condition_cache FROM community; LOAD query_condition_cache;

-- Agent transcripts (Claude Code, Claude Desktop, Codex, Copilot, Cursor, Gemini, Grok)
-- as table functions over the files those tools already write. Read-only; the
-- agent.* views stored in this database are defined on top of it (agent_stream.sql
-- in asubbarao/agent-stream; views persist here, this LOAD is what they need).
INSTALL agent_data FROM community; LOAD agent_data;
INSTALL fts; LOAD fts;                  -- stem() and stopwords only. Never create_fts_index or drop_fts_index on dev: an index drop in the WAL fails replay on 1.5.5 and dev does not start. BM25 is agent.bm25_* tables kept by the agent-stream cron.
INSTALL vss; LOAD vss;                  -- HNSW for the same tables, once they carry embeddings

-- Git, CI logs, rendering and readers every agent reaches through the MCP (2026-09-22).
INSTALL duck_tails   FROM community; LOAD duck_tails;   -- git:// filesystem, git_tree/git_read/git_log/blame; local object store only
INSTALL duck_hunt    FROM community; LOAD duck_hunt;    -- test/build/CI logs as rows: read_duck_hunt_log, read_duck_hunt_workflow_log
INSTALL zipfs        FROM community; LOAD zipfs;        -- zip://run.zip/*.txt — Actions log zips read in place
INSTALL quickjs      FROM community; LOAD quickjs;      -- quickjs(code): JS in the query, SVG charts for tera pages
INSTALL miniplot     FROM community; LOAD miniplot;     -- bar_chart/line_chart/…: Plotly pages from lists (restyle before shipping)
INSTALL minijinja    FROM community; LOAD minijinja;    -- jinja rendering, the tera alternative
INSTALL gh           FROM community; LOAD gh;           -- GitHub API as tables for public repos; private goes through shellfs + gh CLI
INSTALL hostfs       FROM community; LOAD hostfs;       -- lsr(), file_name(), is_dir(): the host filesystem as rows
INSTALL pdf          FROM community; LOAD pdf;          -- read_pdf_*: Poppler text/tables + OCR (asubbarao/duckdb-pdf)
INSTALL parser_tools FROM community; LOAD parser_tools; -- parse_statements/parse_where: SQL as data
INSTALL yaml         FROM community; LOAD yaml;         -- read_yaml
INSTALL quackformers FROM community; LOAD quackformers; -- local embeddings
INSTALL sitting_duck FROM community; LOAD sitting_duck; -- read_ast: source code as syntax trees, 27 languages
INSTALL curl_httpfs  FROM community; LOAD curl_httpfs;  -- httpfs over libcurl for the hosts httpfs cannot reach
INSTALL postgres; LOAD postgres;                        -- ATTACH local/scratch Postgres (never staging/demo/prod for writes)
INSTALL sqlite;   LOAD sqlite;                          -- ATTACH sqlite files (the app's test databases)

-- ---------------------------------------------------------------------------
-- 2. Configuration (all GLOBAL unless marked). Defaults are DuckDB 1.5.5 on this
--    48 GiB / 15-core Mac.
-- ---------------------------------------------------------------------------
-- memory_limit          default 38.3 GiB (80% of RAM); alias max_memory. One tenant of a
--                       laptop that also runs an IDE and Docker.
SET GLOBAL memory_limit = '24GiB';
-- threads               default 15 (5P+10E); alias worker_threads. Leave cores for the desktop.
SET GLOBAL threads = 10;
-- scheduler_process_partial   default false. Fairness between concurrent agents' queries.
SET GLOBAL scheduler_process_partial = true;
-- allocator_background_threads default false. Return freed arenas to the OS; a weeks-long
--                       process otherwise holds its high-water mark forever.
SET GLOBAL allocator_background_threads = true;
-- temp_directory        default '<dbfile>.tmp', relative under launchd (cwd '/'). Absolute.
SET GLOBAL temp_directory = getenv('HOME') || '/.duck/tmp';
-- max_temp_directory_size default 90% of disk. Not an acceptable blast radius unattended.
SET GLOBAL max_temp_directory_size = '50GiB';
-- preserve_insertion_order default true. Stated: row order is data.
SET GLOBAL preserve_insertion_order = true;
-- default_null_order    default NULLS_LAST; default_order default ASCENDING. Stated so an
--                       ORDER BY means the same thing here as in a fresh CLI.
SET GLOBAL default_null_order = 'NULLS_LAST';
SET GLOBAL default_order = 'ASCENDING';
-- TimeZone              default = OS zone (America/Los_Angeles). A daemon must not change the
--                       meaning of a timestamp because the laptop moved or DST flipped.
SET GLOBAL TimeZone = 'UTC';
-- checkpoint_threshold  default 16 MiB; alias wal_autocheckpoint. Fewer checkpoint pauses
--                       under many writers; longer WAL replay after an unclean stop is cheap here.
SET GLOBAL checkpoint_threshold = '128MiB';
-- http_timeout          default 30 (SECONDS). Crawl targets stall. httpfs's own client only —
--                       crawler/webbed use their own HTTP stacks.
SET GLOBAL http_timeout = 120;
-- http_retries          default 3;  http_retry_wait_ms default 100 (backoff factor 4).
SET GLOBAL http_retries = 5;
SET GLOBAL http_retry_wait_ms = 500;
-- httpfs_connection_caching default false; http_keep_alive default true. Reuse connections
--                       in a process that lives for weeks.
SET GLOBAL httpfs_connection_caching = true;
SET GLOBAL http_keep_alive = true;
-- enable_external_file_cache default true. Stated: the biggest win a persistent server has
--                       over a fresh CLI. Validation stays VALIDATE_ALL.
SET GLOBAL enable_external_file_cache = true;
-- enable_progress_bar   default = TTY-dependent (LOCAL — the one session-only line; stdin is
--                       a pipe so it is already false; stated for this connection).
SET enable_progress_bar = false;
-- enable_checkpoint_on_shutdown  default on (GLOBAL). launchd stops us with SIGTERM; fold the
--                       WAL so the next start is a plain open.
PRAGMA enable_checkpoint_on_shutdown;
-- Considered, left at default: errors_as_json (false — JSON errors in launchd logs read worse
--   than they help), storage_compatibility_version (fixed at file creation), custom_user_agent
--   and allow_community_extensions (cannot be changed while running; the latter defaults true
--   and nothing may ever set it false), every profiling/progress pragma (LOCAL — would reach
--   no quack client), enable_object_cache ("[PLACEHOLDER] does nothing"),
--   enable_http_metadata_cache / parquet_metadata_cache (stale on a crawler host),
--   arrow_*, index/join/pivot thresholds (no measured workload), log_query_path (per-connection
--   AND overwrites in place on restart — corrupts; see 4).

-- ---------------------------------------------------------------------------
-- 3. Security. Compatible with the three must-keeps: community extensions load,
--    outbound HTTP to any host, local files under $HOME. The stricter block that
--    breaks them is at the bottom, commented out. lock_configuration is DEAD LAST.
-- ---------------------------------------------------------------------------
-- allow_unsigned_extensions          default false. Keep: unsigned = unreviewed native code.
SET GLOBAL allow_unsigned_extensions = false;
-- allow_extensions_metadata_mismatch default false. Keep: wrong-build binaries are UB in-process.
SET GLOBAL allow_extensions_metadata_mismatch = false;
-- autoinstall_known_extensions       default true -> false: no query may trigger a silent
--                                    download. Everything needed is INSTALLed in 1.
SET GLOBAL autoinstall_known_extensions = false;
-- autoload_known_extensions          default true, kept: a bare https:// read autoloads the
--                                    already-installed httpfs. Loading is local; the download
--                                    path is closed above.
SET GLOBAL autoload_known_extensions = true;
-- (allow_persistent_secrets / secret_directory are in section 0 -- they must precede every LOAD.)
-- allow_unredacted_secrets           default false. Keep: else duckdb_secrets() prints tokens.
SET GLOBAL allow_unredacted_secrets = false;
-- disabled_filesystems               default ''. Names on 1.5.5: LocalFileSystem,
--                                    HTTPFileSystem, S3FileSystem (also gs://, r2://),
--                                    HuggingFaceFileSystem. One-way; typos are accepted
--                                    silently and the value is NOT reflected back in
--                                    duckdb_settings() — audit by probing hf://.
SET GLOBAL disabled_filesystems = 'HuggingFaceFileSystem';
-- Not hardening, by design: once shellfs is loaded, any quack client can run shell via
-- read_csv('cmd |'). No setting compatible with crawling prevents it; the only control is
-- quack_authorization_function (see 5). max_expression_depth is per-connection in practice
-- despite being labelled GLOBAL — setting it here would protect nobody.

-- ---------------------------------------------------------------------------
-- 4. Logging — "we should know every query that runs through it."
--    ONE enable_logging call. It is instance-wide (proven to capture other connections
--    of the same process, i.e. every quack client), it appends across restarts, and
--    with buffer 0 each entry is on disk before the next statement. A second call
--    would replace the first, so every type goes in this list.
-- ---------------------------------------------------------------------------
-- Metrics rows are written only by a connection that has profiling on, and every profiling
-- setting (enable_profiling, profiling_mode, custom_profiling_settings) is LOCAL on 1.5.5:
-- "cannot be set globally". Quack opens a fresh connection per client, so this file cannot
-- turn it on for them; a session that wants metrics runs SET enable_profiling = 'no_output'.
-- enable_logging(types, level, storage, storage_config, storage_path, storage_normalize,
--                storage_buffer_size)
--   types               ['QueryLog','HTTP','Quack','Metrics'] -- registered types: QueryLog,
--                         FileSystem, HTTP, PhysicalOperator, Metrics, Quack. FileSystem and
--                         PhysicalOperator stay off: the 10-minute agent-stream rebuild alone
--                         reads every transcript file, which would flood the log.
--   level               unset -> derived (DEBUG) from the types; a manual
--                         SET logging_level='DEBUG' also floods the file with Transaction rows.
--   storage             'file'  (default 'memory'; CLI default 'shell_log_storage' — moving off
--                         it makes DuckDB print one warning that console warnings go to the file)
--   storage_path        a path ENDING in .csv = ONE denormalized file (every row carries its own
--                         context columns); no suffix = a directory with a two-file normalized
--                         pair — rejected because context_id is reissued after a restart. The
--                         docs page states the opposite; the binary does this.
--   storage_config      unset (same thing as storage_path, as a struct)
--   storage_normalize   unset (passing it alongside storage_path errors on 1.5.5)
--   storage_buffer_size 0 (default 2048): every entry on disk before the next statement.
CALL enable_logging(['QueryLog', 'HTTP', 'Quack', 'Metrics'],
                    storage := 'file',
                    storage_path := getenv('HOME') || '/.duck/logs/duckdb_log.csv',
                    storage_buffer_size := 0);

-- Read-back through DuckDB's own log views: duckdb_logs follows the active storage, so it reads
-- the file (verified 2026-09-22: 1.1M rows), and duckdb_logs_parsed(type) returns each
-- structured type's declared columns. These views are names for those, nothing more.
DROP VIEW IF EXISTS duck_log;
CREATE OR REPLACE VIEW query_log AS      -- every SQL statement executed on this instance
SELECT * EXCLUDE (type, message), message AS query FROM duckdb_logs WHERE type = 'QueryLog';
CREATE OR REPLACE VIEW http_log AS       -- outbound HTTP, request/response structs
FROM duckdb_logs_parsed('HTTP');
CREATE OR REPLACE VIEW quack_log AS      -- every message over the wire; PREPARE_REQUEST rows carry the client's SQL
FROM duckdb_logs_parsed('Quack');
CREATE OR REPLACE VIEW metrics_log AS    -- per-query profiling metrics
FROM duckdb_logs_parsed('Metrics');

-- Keep historical enforcement records; this table does not impose an execution policy.
CREATE TABLE IF NOT EXISTS query_enforcement_events (
    event_id UUID PRIMARY KEY,
    detected_at TIMESTAMP WITH TIME ZONE NOT NULL,
    server_id VARCHAR NOT NULL,
    connection_id VARCHAR,
    query_started_at TIMESTAMP,
    query VARCHAR NOT NULL,
    action VARCHAR NOT NULL,
    reason VARCHAR NOT NULL,
    UNIQUE (connection_id, action)
);

-- ---------------------------------------------------------------------------
-- 5. Serve. Every listener's port comes from _ports: the defaults are inline (scalarfs
--    data+varchar:), DEV_<SERVICE>_PORT in the environment overrides one, and the serve calls
--    read the chosen value through getvariable(). A second instance is the same file with
--    different DEV_*_PORT values — no edit, no conflict.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE _ports AS
SELECT service,
       coalesce(nullif(getenv('DEV_' || upper(service) || '_PORT'), ''), default_port) AS port,
       CASE WHEN nullif(getenv('DEV_' || upper(service) || '_PORT'), '') IS NOT NULL
            THEN 'env' ELSE 'default' END AS source
FROM read_csv('data+varchar:service,default_port
quack,9494
quackapi,9495
mcp,9496', header := true, columns := {'service': 'VARCHAR', 'default_port': 'VARCHAR'});

SELECT CASE WHEN len(list_filter(array_agg(try_cast(port AS INTEGER)), p -> p IS NULL)) > 0
            THEN error('_ports: a DEV_*_PORT is not an integer') ELSE 'ports ok' END AS ports_gate
FROM _ports;

SET VARIABLE quack_uri     = 'quack:localhost:' || (SELECT port FROM _ports WHERE service = 'quack');
SET VARIABLE quackapi_port = (SELECT port FROM _ports WHERE service = 'quackapi')::INTEGER;
SET VARIABLE mcp_port      = (SELECT port FROM _ports WHERE service = 'mcp')::INTEGER;
SET VARIABLE otlp_dir      = getenv('HOME') || '/.duck/otlp';

-- quack_identify(name, hostname, region, provider, meta) -- all default NULL; meta is JSON merged
--   with the always-present duckdb_version and platform. Read back with whoami().
CALL quack_identify(name := 'dev', hostname := 'localhost', region := 'local', provider := 'local',
                    meta := '{"role": "dev-duckdb"}');

-- quack_serve(uri, token := NULL, allow_other_hostname := false, disable_ssl := false)
--   token  min 4 chars; the contents of ~/.duck/token via the environment. Unset env => ''
--          => "token must be at least 4 characters" => init fails => launchd restarts. Fails closed.
--   Returns (listen_uri, listen_url, auth_token) immediately; auth_token is not persisted.
CREATE OR REPLACE TABLE _quack_serve AS
SELECT now() AS started_at, listen_uri, listen_url
FROM quack_serve(getvariable('quack_uri'), token := getenv('QUACK_TOKEN'));

DROP MACRO IF EXISTS agent_crawl;
DROP MACRO IF EXISTS dev_gate;

-- quackapi in this same process: HTTP routes over dev on 127.0.0.1, no token.
--   /sql         runs anything (DDL, DML, several statements; last result returned) by looping
--                back through quack — query() alone takes only one SELECT.
--   /query       one SELECT.
--   /v1/logs, /v1/traces, /v1/metrics   OTLP/HTTP JSON ingest: each request body lands as one
--                raw file under otlp_dir/signal=<x>/<uuid>.json; the otlp_* views read them back.
-- A route body is stored text run on another connection, where these variables do not exist,
-- so the statements that need the quack URI or otlp_dir are built here and run through quack.
-- quackapi_serve sets preserve_insertion_order = false for the process.
INSTALL quackapi FROM community; LOAD quackapi;
FROM quack_query(getvariable('quack_uri'),
  replace(replace($routes$
CREATE OR REPLACE ROUTE sql POST '/sql'
  AS SELECT * FROM quack_query('@QUACK_URI', $sql, token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE ROUTE query POST '/query' AS SELECT * FROM query($sql);
CREATE OR REPLACE ROUTE otlp_logs POST '/v1/logs' AS
  COPY (SELECT $body::VARCHAR AS payload, 'logs' AS signal) TO '@OTLP_DIR'
  (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', PARTITION_BY (signal), FILENAME_PATTERN '{uuid}', FILE_EXTENSION 'json', OVERWRITE_OR_IGNORE true);
CREATE OR REPLACE ROUTE otlp_traces POST '/v1/traces' AS
  COPY (SELECT $body::VARCHAR AS payload, 'traces' AS signal) TO '@OTLP_DIR'
  (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', PARTITION_BY (signal), FILENAME_PATTERN '{uuid}', FILE_EXTENSION 'json', OVERWRITE_OR_IGNORE true);
CREATE OR REPLACE ROUTE otlp_metrics POST '/v1/metrics' AS
  COPY (SELECT $body::VARCHAR AS payload, 'metrics' AS signal) TO '@OTLP_DIR'
  (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', PARTITION_BY (signal), FILENAME_PATTERN '{uuid}', FILE_EXTENSION 'json', OVERWRITE_OR_IGNORE true);
-- One empty payload per signal, so each view below binds on a fresh instance (a glob that
-- matches nothing fails CREATE VIEW); it reads as zero rows.
COPY (SELECT '{"resourceLogs":[]}' AS payload, 'logs' AS signal
      UNION ALL SELECT '{"resourceSpans":[]}', 'traces'
      UNION ALL SELECT '{"resourceMetrics":[]}', 'metrics')
TO '@OTLP_DIR' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', PARTITION_BY (signal),
                FILENAME_PATTERN '_seed', FILE_EXTENSION 'json', OVERWRITE_OR_IGNORE true);
-- The otlp extension's readers over the raw files: typed rows, nothing parsed by hand. Metrics
-- are one view per shape because OTLP metric shapes have different schemas.
CREATE OR REPLACE VIEW otlp_logs AS FROM read_otlp_logs('@OTLP_DIR/signal=logs/*.json');
CREATE OR REPLACE VIEW otlp_traces AS FROM read_otlp_traces('@OTLP_DIR/signal=traces/*.json');
CREATE OR REPLACE VIEW otlp_metrics_sum AS FROM read_otlp_metrics_sum('@OTLP_DIR/signal=metrics/*.json');
CREATE OR REPLACE VIEW otlp_metrics_gauge AS FROM read_otlp_metrics_gauge('@OTLP_DIR/signal=metrics/*.json');
CREATE OR REPLACE VIEW otlp_metrics_histogram AS FROM read_otlp_metrics_histogram('@OTLP_DIR/signal=metrics/*.json');
CREATE OR REPLACE VIEW otlp_metrics_exp_histogram AS FROM read_otlp_metrics_exp_histogram('@OTLP_DIR/signal=metrics/*.json');
SELECT 'routes ok' AS routes
$routes$, '@QUACK_URI', getvariable('quack_uri')), '@OTLP_DIR', getvariable('otlp_dir')),
  token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE TABLE _quackapi_serve AS
SELECT now() AS started_at, * FROM quackapi_serve(getvariable('quackapi_port'), host := '127.0.0.1');

-- The `dev` MCP, in this same process (claude mcp add --transport http dev
-- http://localhost:<mcp port>/mcp). No second DuckDB: the tools run here. `query` is one SELECT;
-- `sql` loops back through quack like /sql, so it runs anything.
-- BEGIN SYSTEM EXTENSION CATALOG
-- Two jobs in the existing system DuckDB; captured URLs are never fetched again.
LOAD markdown; LOAD crawler; LOAD webbed; LOAD http_client; INSTALL yaml FROM community; LOAD yaml; LOAD cronjob;
CREATE SCHEMA IF NOT EXISTS agents;
CREATE TABLE IF NOT EXISTS main.ext_catalog_community_history AS
SELECT now() AS fetched_at, * FROM crawl([]::VARCHAR[], workers := 8, batch_size := 8, timeout := 5,
    delay := 0, follow := '', max_depth := 0, cache := false, cache_ttl := 24, max_results := 0,
    state_table := '', respect_robots := true, "extract" := [], user_agent := 'System Quack catalog') WHERE false;
CREATE OR REPLACE VIEW main.ext_catalog_documents AS
SELECT * FROM main.ext_catalog_community_history QUALIFY fetched_at = max(fetched_at) OVER (PARTITION BY url);
CREATE OR REPLACE TABLE main.ext_catalog_jobs AS
SELECT name: 'index', schedule: '0 0 */6 * * *', sql: $index$
WITH extlist AS (
    SELECT DISTINCT url: format('https://duckdb.org{}', link.href)
    FROM crawl(['https://duckdb.org/community_extensions/list_of_extensions'], workers := 8, batch_size := 8,
        timeout := 5, delay := 0, follow := '', max_depth := 0, cache := false, cache_ttl := 24,
        max_results := 1, state_table := '', respect_robots := true, "extract" := [], user_agent := 'System Quack catalog'),
        UNNEST(html_extract_links(html.document::HTML)) AS links(link)
    WHERE CASE WHEN status = 200 THEN true ELSE error(coalesce(error, 'index fetch failed')) END
      AND starts_with(link.href, '/community_extensions/extensions/')
), pending AS (
    SELECT *, batch: (row_number() OVER (ORDER BY url) - 1) // 8 FROM extlist
    WHERE url NOT IN (SELECT url FROM main.ext_catalog_documents)
), statements AS (
    SELECT format($fetch$INSERT INTO main.ext_catalog_community_history BY NAME
SELECT now() AS fetched_at, * FROM crawl([{}], workers := 8, batch_size := 8, timeout := 5,
    delay := 0, follow := '', max_depth := 0, cache := false, cache_ttl := 24, max_results := {},
    state_table := '', respect_robots := true, "extract" := [], user_agent := 'System Quack catalog');$fetch$,
        string_agg(format('$url${}$url$', url), ','), len(list(url))) AS statement FROM pending GROUP BY batch
), fired AS (
    SELECT array_agg(http_post(listen_url || '/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', statement))) AS responses
    FROM statements, quackapi_servers()
)
SELECT CASE WHEN response.status::INTEGER = 200 THEN response.body ELSE error(response::VARCHAR) END AS result
FROM fired, UNNEST(responses) AS results(response);
$index$
UNION ALL BY NAME SELECT name: 'documents', schedule: '0 */5 * * * *', sql: $documents$
WITH urls AS (
    SELECT replace(link.href, 'https://github.com/duckdb/community-extensions/blob/', 'https://raw.githubusercontent.com/duckdb/community-extensions/') AS url
    FROM main.ext_catalog_documents d, UNNEST(html_extract_links(d.html.document::HTML)) AS links(link) WHERE starts_with(d.url, 'https://duckdb.org/community_extensions/extensions/') AND ends_with(link.href, '/description.yml')
    UNION
    SELECT 'https://github.com/' || yaml_extract_string(CASE WHEN ends_with(url, '/description.yml') AND status = 200 THEN html.document END, '$.repo.github') AS url
    FROM main.ext_catalog_documents WHERE ends_with(url, '/description.yml') AND status = 200 AND yaml_valid(html.document)
), pending AS (
    SELECT *, batch: (row_number() OVER (ORDER BY url) - 1) // 8 FROM urls
    WHERE url IS NOT NULL AND url NOT IN (SELECT url FROM main.ext_catalog_documents)
), statements AS (
    SELECT format($fetch$INSERT INTO main.ext_catalog_community_history BY NAME
SELECT now() AS fetched_at, * FROM crawl([{}], workers := 8, batch_size := 8, timeout := 5,
    delay := 0, follow := '', max_depth := 0, cache := false, cache_ttl := 24, max_results := {},
    state_table := '', respect_robots := true, "extract" := [], user_agent := 'System Quack catalog');$fetch$,
        string_agg(format('$url${}$url$', url), ','), len(list(url))) AS statement FROM pending GROUP BY batch
), fired AS (
    SELECT array_agg(http_post(listen_url || '/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', statement))) AS responses
    FROM statements, quackapi_servers()
)
SELECT CASE WHEN response.status::INTEGER = 200 THEN response.body ELSE error(response::VARCHAR) END AS result
FROM fired, UNNEST(responses) AS results(response);
BEGIN; CREATE OR REPLACE TABLE agents.ext_catalog AS SELECT merged.* FROM (SELECT CASE WHEN n.extension_name IS NULL THEN o ELSE n END AS merged
FROM agents.ext_catalog o FULL OUTER JOIN main.ext_catalog_parsed n USING(extension_name));
CREATE OR REPLACE TABLE agents.ext_catalog_functions AS SELECT merged.* FROM (SELECT CASE WHEN n.extension_name IS NULL THEN o ELSE n END AS merged
FROM agents.ext_catalog_functions o FULL OUTER JOIN main.ext_catalog_function_docs n USING(extension_name, source, table_index, row_index));
COMMIT;
$documents$;
CREATE OR REPLACE VIEW main.ext_catalog_parsed AS
WITH community AS (
    SELECT d.*, extension_name: regexp_extract(d.url, '/([^/]+)\.html$', 1), yaml_url: replace(link.href, 'https://github.com/duckdb/community-extensions/blob/', 'https://raw.githubusercontent.com/duckdb/community-extensions/')
    FROM main.ext_catalog_documents d, UNNEST(html_extract_links(d.html.document::HTML)) AS links(link) WHERE starts_with(d.url, 'https://duckdb.org/community_extensions/extensions/') AND ends_with(link.href, '/description.yml')
), metadata AS (
    SELECT *, metadata: yaml_to_json((CASE WHEN ends_with(url, '/description.yml') AND status = 200 AND yaml_valid(html.document) THEN html.document END)::YAML),
           github_repo: metadata->>'$.repo.github' FROM main.ext_catalog_documents WHERE ends_with(url, '/description.yml')
)
SELECT c.extension_name, c.url AS community_url, c.yaml_url, c.fetched_at, y.github_repo, y.metadata,
       c.status AS community_status, y.status AS yaml_status, g.status AS github_status,
       html_to_duck_blocks(c.html.document::HTML) AS community_blocks, html_extract_tables_json(c.html.document::HTML) AS community_tables,
       html_to_duck_blocks(g.html.document::HTML) AS github_blocks, html_extract_tables_json(g.html.document::HTML) AS github_tables, duck_blocks_to_md(github_blocks) AS github_markdown
FROM community c LEFT JOIN metadata y ON y.url = c.yaml_url
LEFT JOIN main.ext_catalog_documents g ON g.url = 'https://github.com/' || y.github_repo;
CREATE TABLE IF NOT EXISTS agents.ext_catalog AS FROM main.ext_catalog_parsed;
CREATE OR REPLACE VIEW main.ext_catalog_function_docs AS
WITH docs AS (
    SELECT extension_name, github_repo, source: 'community', UNNEST(community_tables) AS doc FROM agents.ext_catalog
    UNION ALL BY NAME SELECT extension_name, github_repo, source: 'github', UNNEST(github_tables) AS doc FROM agents.ext_catalog
), rows AS (
    SELECT * EXCLUDE(doc, row_index), doc.*, row_index, row_data: doc.table_data[row_index], names: list_transform(doc.headers, h -> lower(replace(h, ' ', '_')))
    FROM docs, UNNEST(range(1, len(doc.table_data)+1)) AS positions(row_index)
)
SELECT * EXCLUDE(table_data, names), function_name: row_data[coalesce(list_position(names, 'function_name'), list_position(names, 'function'))],
       function_type: row_data[list_position(names, 'function_type')], description: row_data[list_position(names, 'description')],
       examples: row_data[coalesce(list_position(names, 'examples'), list_position(names, 'example'))]
FROM rows WHERE function_name IS NOT NULL;
CREATE TABLE IF NOT EXISTS agents.ext_catalog_functions AS FROM main.ext_catalog_function_docs;
WITH statements AS (
    SELECT format($register$SELECT cron($job${}$job$, $schedule${}$schedule$) AS job_id$register$, sql, schedule) AS statement
    FROM main.ext_catalog_jobs WHERE (trim(sql), schedule) NOT IN (SELECT (trim(query), schedule) FROM cron_jobs())
), fired AS (
    SELECT array_agg(http_post(listen_url || '/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', statement))) AS responses FROM statements, quackapi_servers()
)
SELECT CASE WHEN response.status::INTEGER = 200 THEN response.body ELSE error(response::VARCHAR) END AS registration FROM fired, UNNEST(responses) AS results(response);
SELECT *, 'ext_catalog' AS table_name FROM (DESCRIBE agents.ext_catalog) UNION ALL BY NAME SELECT *, 'ext_catalog_functions' AS table_name FROM (DESCRIBE agents.ext_catalog_functions);
SELECT *, 'ext_catalog' AS table_name FROM (SUMMARIZE agents.ext_catalog) UNION ALL BY NAME SELECT *, 'ext_catalog_functions' AS table_name FROM (SUMMARIZE agents.ext_catalog_functions);
-- END SYSTEM EXTENSION CATALOG

INSTALL duckdb_mcp FROM community; LOAD duckdb_mcp;
PRAGMA mcp_publish_tool('query',
  'Run one SELECT against dev. Returns at most 100 rows.',
  'SELECT * FROM query($sql) LIMIT 100',
  '{"sql": {"type": "string", "description": "one SELECT"}}', '["sql"]', 'markdown');
PRAGMA mcp_publish_tool('sql',
  'Run any SQL against dev (DDL, DML, COPY, several statements). Returns the last statement''s rows, at most 100.',
  replace('SELECT * FROM quack_query(''@QUACK_URI'', $sql, token := getenv(''QUACK_TOKEN'')) LIMIT 100',
          '@QUACK_URI', getvariable('quack_uri')),
  '{"sql": {"type": "string", "description": "any SQL"}}', '["sql"]', 'markdown');
-- Agent-facing tools over dev data: the agent stream (BM25 over agent.stream, read a session,
-- what the user typed), self-dispatch as a call, and the extension catalog.
-- stream_search is agent_stream_search.sql itself (message-level BM25 + vector, reciprocal-rank fusion), its example literal bound to $q, so the search
-- query exists in one file. A PRAGMA is expanded when parsed, so the text is read one statement earlier.
SET VARIABLE stream_search_sql = (SELECT rtrim(trim(replace(content, '''launchctl plist wrapper server exits log''', '$q::VARCHAR')), ';')
                                  FROM read_text(getenv('HOME') || '/.duck/agent_stream/agent_stream_search.sql'));
PRAGMA mcp_publish_tool('stream_search',
  'Search every agent conversation on this machine (Claude, Claude Desktop, Codex): message-level BM25 fused with vector similarity (reciprocal rank). One row per matching session, best first, with its best messages; then read one with stream_session.',
  getvariable('stream_search_sql'),
  '{"q": {"type": "string", "description": "search words or a question"}}', '["q"]', 'markdown');
PRAGMA mcp_publish_tool('stream_session',
  'Read one conversation back, hour by hour, in order: every user, agent and tool_call message.',
  'SELECT hour, messages, content FROM agent.stream_hour WHERE session_id = $session_id ORDER BY hour LIMIT 100',
  '{"session_id": {"type": "string"}}', '["session_id"]', 'markdown');
PRAGMA mcp_publish_tool('user_messages',
  'What the user typed in the last N hours, one row per session per hour, in order. Harness-injected text is already excluded.',
  'SELECT hour, system, session_id, array_agg(message_content ORDER BY ts) AS messages
   FROM agent.stream
   WHERE message_role = ''user'' AND ts >= now() - to_hours($hours::INTEGER)
   GROUP BY ALL ORDER BY hour DESC LIMIT 100',
  '{"hours": {"type": "integer", "description": "how far back"}}', '["hours"]', 'markdown');
PRAGMA mcp_publish_tool('self_dispatch',
  'Self-dispatch: rows_sql is a SELECT with a column named statement; every statement is posted to dev''s own /sql in one array_agg and the results come back one row each. Use when a table function needs a value from a column, or to fan out per row.',
  'WITH statements AS (SELECT * FROM query($rows_sql)),
   fired AS (SELECT array_agg(http_post_form(listen_url || ''/sql'', MAP {}, MAP {''sql'': statement})) AS responses
             FROM statements, quackapi_servers())
   SELECT response.status AS status, json_extract_string(response.body, ''$'') AS rows_json
   FROM fired, UNNEST(responses) AS fired_responses(response) LIMIT 100',
  '{"rows_sql": {"type": "string", "description": "SELECT ... AS statement FROM ..."}}', '["rows_sql"]', 'markdown');
PRAGMA mcp_publish_tool('ext_docs',
  'Read the captured community and GitHub pages for an extension as complete WEBBED blocks.',
  $$SELECT 'community' AS source, block.* FROM agents.ext_catalog, UNNEST(community_blocks) AS blocks(block) WHERE extension_name = $extension
    UNION ALL BY NAME SELECT 'github' AS source, block.* FROM agents.ext_catalog, UNNEST(github_blocks) AS blocks(block) WHERE extension_name = $extension
    ORDER BY source, element_order$$,
  '{"extension":{"type":"string"}}', '["extension"]', 'markdown');
-- Git, CI logs and rendering as tools, so no agent needs a local client for them.
PRAGMA mcp_publish_tool('git_tree',
  'Files of a local git repository at a ref (duck_tails). repo is an absolute path to a checkout or bare clone; ref is HEAD, a branch, a tag or a sha.',
  'SELECT file_path, file_ext, kind, size_bytes, git_uri FROM git_tree($repo, $ref) WHERE kind = ''file'' ORDER BY file_path LIMIT 100',
  '{"repo": {"type": "string"}, "ref": {"type": "string", "description": "default HEAD"}}', '["repo", "ref"]', 'markdown');
PRAGMA mcp_publish_tool('git_read',
  'One file from a local git repository at a ref, as text (duck_tails). Binary files come back with text NULL.',
  'SELECT file_path, ref, size_bytes, encoding, text FROM git_read(''git://'' || $repo || ''/'' || $path || ''@'' || $ref)',
  '{"repo": {"type": "string"}, "path": {"type": "string", "description": "path inside the repo"}, "ref": {"type": "string", "description": "HEAD, branch, tag or sha"}}', '["repo", "path", "ref"]', 'markdown');
PRAGMA mcp_publish_tool('ci_hunt',
  'Parse a CI job log inside a GitHub Actions log zip with duck_hunt. zip is an absolute path; glob selects files inside it (e.g. *Backend Tests Shard*.txt); format is a duck_hunt format name, auto, or regexp:<pattern with named groups>.',
  'SELECT event_type, status, severity, tool_name, ref_file, ref_line, test_name, message, execution_time, log_file, log_line_start
   FROM read_duck_hunt_log(''zip://'' || $zip || ''/'' || $glob, $format) LIMIT 100',
  '{"zip": {"type": "string"}, "glob": {"type": "string"}, "format": {"type": "string"}}', '["zip", "glob", "format"]', 'markdown');
PRAGMA mcp_publish_tool('render',
  'Render a tera template file with a JSON context and return the text (a page, a .sql, a .md). Write it out with the sql tool''s COPY if a file is wanted.',
  'SELECT tera_render((SELECT content FROM read_text($template)), $ctx::JSON, autoescape := false) AS rendered',
  '{"template": {"type": "string", "description": "absolute path of the template"}, "ctx": {"type": "string", "description": "JSON object"}}', '["template", "ctx"]', 'markdown');
PRAGMA mcp_server_start('http', 'localhost', getvariable('mcp_port'),
  '{"builtin_tools": false, "background": true, "default_result_format": "markdown"}');

-- What is listening, as data: every listener this process started.
CREATE OR REPLACE TABLE _listeners AS
SELECT now() AS at, 'quack' AS service, listen_uri AS address FROM quack_server_list()
UNION ALL SELECT now(), 'quackapi', listen_url FROM quackapi_servers()
UNION ALL SELECT now(), 'mcp', 'http://localhost:' || getvariable('mcp_port') || '/mcp';

-- quackapi_serve sets enable_logging = false for the whole process (its default "battery", to spare
-- HTTP throughput from QueryLog), which silently switched off section 4's logging. Re-apply the same
-- call now that every listener is up, so nothing that starts earlier can turn it off.
CALL enable_logging(['QueryLog', 'HTTP', 'Quack', 'Metrics'],
                    storage := 'file',
                    storage_path := getenv('HOME') || '/.duck/logs/duckdb_log.csv',
                    storage_buffer_size := 0);

-- Agent stream refresh, every 5 minutes, the only refresher. agent_stream.sql is plain SQL that runs
-- in the cron connection itself: no quack_query or /sql loopback, no PRAGMA, no CHECKPOINT; BM25 is
-- ordinary tables (agent.bm25_length, agent.bm25_posting) kept by DELETE/INSERT, so a refresh never
-- drops an index. cron() stores the text at registration: after editing the file, cron_delete the
-- job and register it again (or restart dev).
SELECT cron((SELECT content FROM read_text(getenv('HOME') || '/.duck/agent_stream/agent_stream.sql')),
            '0 */5 * * * *') AS agent_stream_refresh_job;

-- ---------------------------------------------------------------------------
-- 6. Record the effective configuration, whole rows, every column.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE TABLE _setup_settings AS SELECT now() AS recorded_at, * FROM duckdb_settings();
CREATE TABLE IF NOT EXISTS _setup_settings_history AS SELECT * FROM _setup_settings LIMIT 0;
INSERT INTO _setup_settings_history BY NAME SELECT * FROM _setup_settings;

-- ---------------------------------------------------------------------------
-- 7. Refuse to serve a crippled or over-permissive instance. Zero rows = pass;
--    a row raises, the CLI exits, launchd logs it and restarts.
-- ---------------------------------------------------------------------------
-- error(message) -- only parameter
SELECT error('setup.sql: refusing to serve -- ' || name || ' = ' || value) AS setup_guard
FROM duckdb_settings()
WHERE (name = 'allow_community_extensions' AND value <> 'true')
   OR (name = 'enable_external_access'     AND value <> 'true')
   OR (name = 'allow_unsigned_extensions'  AND value <> 'false')
   OR (name = 'allow_unredacted_secrets'   AND value <> 'false');

-- ---------------------------------------------------------------------------
-- 8. THE LOCK — last statement. Global in the strong sense: a connection opened
--    after it (what quack does per client) cannot SET / PRAGMA / RESET anything.
--    INSTALL, LOAD, ATTACH, HTTP reads and CREATE PERSISTENT SECRET still work.
--    Cost: clients cannot SET SESSION over dev.query() either.
-- ---------------------------------------------------------------------------


SET GLOBAL lock_configuration = true;

-- ============================================================================
-- STRICTER BLOCK — commented out. Each line says what it breaks. Must precede the
-- lock; none can be applied to a running server; enable_external_access is one-way.
-- ============================================================================
-- SET GLOBAL allowed_directories = [getenv('HOME') || '/.duck', getenv('HOME') || '/inframe', '/tmp'];
-- SET GLOBAL enable_external_access = false;   -- breaks HTTP reads, INSTALL/LOAD, getenv(); the
--                                              -- allowlist above only means anything under this
-- SET GLOBAL disabled_filesystems = 'HuggingFaceFileSystem,S3FileSystem';  -- breaks s3/gs/r2
-- SET GLOBAL autoload_known_extensions = false; -- every extension must be LOADed by name above
-- SET GLOBAL enable_external_file_cache = false; -- only if clients stop being one trust domain

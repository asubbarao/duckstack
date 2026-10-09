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

-- Queries and Quack requests, from DuckDB's own log; the launchd wrapper's lifecycle events.
CREATE SCHEMA IF NOT EXISTS meta;
CREATE OR REPLACE VIEW meta.query_log AS SELECT * EXCLUDE (type, message), message AS query FROM duckdb_logs WHERE type = 'QueryLog';
CREATE OR REPLACE VIEW meta.quack_events AS
SELECT * EXCLUDE (message), unnest(parse_duckdb_log_message('Quack', message)) FROM duckdb_logs WHERE type = 'Quack';
CREATE OR REPLACE VIEW meta.remote_query_history AS
SELECT timestamp AS started_at, quack_connection_id, client_query_id, query, duration_ms, duration_ms / 1000.0 AS wall_seconds, response_type, error
FROM meta.quack_events WHERE message_type = 'PREPARE_REQUEST' AND server IS NULL AND client_query_id IS NOT NULL;
CREATE OR REPLACE VIEW meta.query_minute AS
SELECT time_bucket(INTERVAL 1 MINUTE, started_at) AS minute, count(started_at) AS queries, count(error) AS errors,
       quantile_cont(duration_ms, 0.50) AS p50_ms, quantile_cont(duration_ms, 0.95) AS p95_ms, quantile_cont(duration_ms, 0.99) AS p99_ms,
       max(duration_ms) AS max_ms, sum(duration_ms) / 1000.0 AS wall_seconds
FROM meta.remote_query_history GROUP BY ALL;
CREATE OR REPLACE VIEW meta.server_events AS
FROM read_json('/Users/aloksubbarao/.duck/logs/server-events*.jsonl', format := 'newline_delimited', union_by_name := true);
-- GET /metrics: Prometheus text, computed per scrape.
CREATE OR REPLACE VIEW meta.prometheus_metrics AS
WITH q AS (
  SELECT count(started_at) AS queries, count(error) AS errors, sum(duration_ms) / 1000.0 AS wall_seconds,
         quantile_cont(duration_ms, 0.5) FILTER (started_at > now() - INTERVAL 5 MINUTE) AS p50_ms,
         quantile_cont(duration_ms, 0.95) FILTER (started_at > now() - INTERVAL 5 MINUTE) AS p95_ms
  FROM meta.remote_query_history
), duck AS (
  SELECT pid, memory_percent FROM sazgar_processes() WHERE name = 'duckdb'
), samples AS (
  SELECT 'duckdb_quack_queries_total' AS name, 'counter' AS kind, '' AS labels, queries AS value FROM q
  UNION ALL SELECT 'duckdb_quack_query_errors_total', 'counter', '', errors FROM q
  UNION ALL SELECT 'duckdb_quack_query_wall_seconds_total', 'counter', '', wall_seconds FROM q
  UNION ALL SELECT 'duckdb_quack_query_ms_5m', 'gauge', '{quantile="0.5"}', p50_ms FROM q
  UNION ALL SELECT 'duckdb_quack_query_ms_5m', 'gauge', '{quantile="0.95"}', p95_ms FROM q
  UNION ALL SELECT 'duckdb_log_lag_seconds', 'gauge', '', date_diff('millisecond', max(timestamp), now()) / 1000.0 FROM duckdb_logs
  UNION ALL SELECT 'duckdb_memory_usage_bytes', 'gauge', '{tag="' || tag || '"}', memory_usage_bytes FROM duckdb_memory()
  UNION ALL SELECT 'duckdb_temporary_storage_bytes', 'gauge', '', sum(temporary_storage_bytes) FROM duckdb_memory()
  UNION ALL SELECT 'duckdb_processes', 'gauge', '', count(pid) FROM duck
  UNION ALL SELECT 'duckdb_process_memory_percent_sum', 'gauge', '', sum(memory_percent) FROM duck
  UNION ALL SELECT 'duckdb_cron_jobs', 'gauge', '{status="' || status || '"}', count(job_id) FROM cron_jobs() GROUP BY status
), families AS (
  SELECT name, '# TYPE ' || name || ' ' || kind || '
' || string_agg(name || labels || ' ' || coalesce(value::DOUBLE, 0), '
' ORDER BY labels) AS block
  FROM samples GROUP BY name, kind
)
SELECT string_agg(block, '
' ORDER BY name) || '
' AS text FROM families;

-- Extension catalog. lake.agents.ext_fetch is the raw log: one row per fetch (url, fetched_at, response {status, body}).
-- agents.ext_page is the newest good fetch per url; ext_catalog and ext_docs read it. agents.ext_stale lists the urls
-- missing or older than three days. Hourly, each stale url is fetched by curl through shellfs, one self-dispatched
-- INSERT per url; a failed fetch (curl --fail) lands no row and is retried next hour.
CREATE SCHEMA IF NOT EXISTS agents;
CREATE OR REPLACE VIEW agents.ext_fetch AS FROM lake.agents.ext_fetch;
CREATE OR REPLACE VIEW agents.ext_page AS
SELECT url, max(fetched_at) AS fetched_at, arg_max(response, fetched_at) AS response
FROM lake.agents.ext_fetch WHERE response ->> 'status' = '200' GROUP BY url;
-- ext_url reads each extension's community page, GitHub repo and description.yml off the community list page.
CREATE OR REPLACE VIEW agents.ext_url AS
WITH link AS (
    SELECT unnest(l, recursive := true), generate_subscripts(l, 1) AS i
    FROM (SELECT html_extract_links(parse_html(response ->> 'body')) AS l FROM agents.ext_page
          WHERE url = 'https://duckdb.org/community_extensions/list_of_extensions')
), ext AS (  -- a row of the list's table: the name links to the community page, the link after it is its GitHub repo
    SELECT DISTINCT n.text AS extension_name, 'https://duckdb.org' || n.href AS community, g.href AS github,
           'https://raw.githubusercontent.com/duckdb/community-extensions/main/extensions/' || n.text || '/description.yml' AS yaml
    FROM link n JOIN link g ON g.i = n.i + 1 AND g.text = 'GitHub'
)
UNPIVOT ext ON community, github, yaml INTO NAME kind VALUE url;
CREATE OR REPLACE VIEW agents.ext_stale AS
FROM (SELECT 'list' AS kind, 'https://duckdb.org/community_extensions/list_of_extensions' AS url UNION ALL BY NAME FROM agents.ext_url)
ANTI JOIN (FROM agents.ext_page WHERE fetched_at > now() - INTERVAL 3 DAY) USING (url)
ANTI JOIN (FROM agents.ext_fetch WHERE fetched_at > now() - INTERVAL 5 MINUTE) USING (url);
CREATE OR REPLACE VIEW agents.ext_fetch_errors AS
FROM agents.ext_fetch WHERE response ->> 'status' IS DISTINCT FROM '200';
CREATE OR REPLACE VIEW agents.ext_catalog AS  -- one row per extension; each cell is that kind's response
PIVOT (FROM agents.ext_url JOIN agents.ext_page USING (url)) ON kind IN ('community', 'github', 'yaml') USING any_value(response) GROUP BY extension_name;
CREATE OR REPLACE VIEW agents.ext_docs AS  -- the README: GitHub's <article>, minus its heading permalinks
SELECT extension_name, duck_blocks_to_md(list_filter(html_to_duck_blocks(xml_extract_elements(parse_html(github ->> 'body'), '//article')[1]::VARCHAR),
                                                     b -> NOT coalesce(starts_with(b.attributes['id'], 'user-content-'), false))) AS readme
FROM agents.ext_catalog;
-- Every readthedocs page an extension README links to, saved raw in ext_fetch, as markdown sections.
CREATE OR REPLACE VIEW agents.ext_doc_sections AS
WITH page AS (
    SELECT coalesce(response ->> 'effective_url', url) AS url, duck_blocks_to_md(html_to_duck_blocks((response ->> 'body')::HTML)) AS markdown
    FROM lake.agents.ext_fetch WHERE urlpattern_test('https://*.readthedocs.io/*', url)
), section AS (
    SELECT url, unnest(md_extract_sections(markdown), recursive := true) FROM page
)
SELECT url_host(url) AS site, url || '#' || section_id AS section_url, section_path, level, title, content::VARCHAR AS content,
       md_extract_code_blocks(content) AS code, md_extract_tables_json(content) AS tables
FROM section;
SELECT cron($$
WITH due AS (
    SELECT url FROM (SELECT url, min(kind) AS kind FROM agents.ext_stale GROUP BY url) ORDER BY kind = 'list' DESC, url LIMIT 90
)
SELECT url, http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', tera_render($t$
INSERT INTO lake.agents.ext_fetch BY NAME
SELECT '{{ url }}' AS url, now() AS fetched_at, json_object('status', 200, 'body', content) AS response
FROM read_text('curl -sSL --fail --max-time 30 {{ url }} |')
$t$, json_object('url', url), autoescape := false))) ->> '$.status' AS status
FROM due
$$, '0 15 * * * *');

CREATE SCHEMA IF NOT EXISTS agent;
CREATE OR REPLACE VIEW agent.stream AS
SELECT * REPLACE ('claude' AS source) FROM read_conversations(source := 'claude', path := '/Users/aloksubbarao/.claude')
UNION ALL BY NAME
SELECT * REPLACE ('claude-desktop' AS source) FROM read_conversations(source := 'claude-desktop', path := '/Users/aloksubbarao/Library/Application Support/Claude')
UNION ALL BY NAME
SELECT * REPLACE ('codex' AS source) FROM read_conversations(source := 'codex', path := '/Users/aloksubbarao/.codex');

-- Read every minute by the mac-metrics collector (launchd com.alok.mac-metrics, ~/Documents/mac-metrics-incubator).
CREATE SCHEMA IF NOT EXISTS agents;
CREATE OR REPLACE VIEW agents.mac_query_activity AS
SELECT getenv('QUACK_INSTANCE_ID') AS instance_id, min("timestamp") OVER () AS instance_started_at,
       getenv('QUACK_WRAPPER_PID')::BIGINT AS wrapper_pid,
       "timestamp" AS observed_at, context_id, connection_id, query_id, query AS sql_text,
       getenv('QUACK_NATIVE_LOG') AS source_log, 'query_log_observation' AS observation_kind
FROM meta.query_log;

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

-- Dev DuckDB. launchd runs `duckdb -bail ~/.duck/db/dev.duckdb -init setup.sql` and keeps stdin open.
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
-- Used by the agents.ext_* docs views and meta.prometheus_metrics.
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
-- Dev works in the inframe checkout: duck_tails calls take '.' or no path at all.
FROM cd(getenv('HOME') || '/inframe');

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
  SELECT name, kind, list({labels: labels, value: coalesce(value::DOUBLE, 0)} ORDER BY labels) AS samples FROM samples GROUP BY name, kind
)
SELECT tera_render($p${% for f in families %}# TYPE {{ f.name }} {{ f.kind }}
{% for s in f.samples %}{{ f.name }}{{ s.labels }} {{ s.value }}
{% endfor %}{% endfor %}$p$, json_object('families', list({name: name, kind: kind, samples: samples} ORDER BY name)), autoescape := false) AS text
FROM families;

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
CREATE OR REPLACE VIEW agents.ext_catalog AS  -- one row per extension and kind (community, github, yaml): its newest page
FROM agents.ext_url JOIN agents.ext_page USING (url);
CREATE OR REPLACE VIEW agents.ext_docs AS  -- the README: GitHub's <article>, minus its heading permalinks
SELECT extension_name, duck_blocks_to_md(list_filter(html_to_duck_blocks(xml_extract_elements(parse_html(response ->> 'body'), '//article')[1]::VARCHAR),
                                                     b -> NOT coalesce(starts_with(b.attributes['id'], 'user-content-'), false))) AS readme
FROM agents.ext_catalog WHERE kind = 'github';
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
    SELECT DISTINCT url, kind FROM agents.ext_stale ORDER BY kind = 'list' DESC, url LIMIT 90
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
CREATE OR REPLACE VIEW agents.mac_query_activity AS
SELECT getenv('QUACK_INSTANCE_ID') AS instance_id, min("timestamp") OVER () AS instance_started_at,
       getenv('QUACK_WRAPPER_PID')::BIGINT AS wrapper_pid,
       "timestamp" AS observed_at, context_id, connection_id, query_id, query AS sql_text,
       getenv('QUACK_NATIVE_LOG') AS source_log, 'query_log_observation' AS observation_kind
FROM meta.query_log;

-- What each local branch changed since it left origin/staging, and whether origin has it: the files a PR
-- shows, with no gh. branch_point = shared commits that no other shared commit has as a parent (git's
-- merge base). One row per branch and changed file; filter with WHERE branch_name = ….
CREATE OR REPLACE VIEW branch_diff AS
WITH local_branches AS (
    SELECT * FROM git_branches() WHERE NOT is_remote
), remote_branches AS (
    SELECT branch_name AS remote_branch_name, commit_hash AS remote_commit_hash FROM git_branches() WHERE is_remote
), tracked_branches AS (
    SELECT local_branches.*, remote_branches.remote_branch_name, remote_branches.remote_commit_hash,
           remote_branches.remote_commit_hash IS NOT DISTINCT FROM local_branches.commit_hash AS is_pushed
    FROM local_branches
    LEFT JOIN remote_branches ON remote_branches.remote_branch_name = 'origin/' || local_branches.branch_name
), staging_commits AS (
    SELECT commit_hash FROM git_log('.', 'origin/staging')
), staging_parent_edges AS (
    SELECT commit_hash, parent_hash FROM git_parents('.', 'origin/staging')
), branch_history AS (
    SELECT tracked_branches.branch_name, history.commit_hash
    FROM tracked_branches, LATERAL git_log_each(tracked_branches.repo_path, tracked_branches.commit_hash) history
), shared_history AS (
    SELECT * FROM branch_history SEMI JOIN staging_commits USING (commit_hash)
), shared_parents AS (
    SELECT shared_history.branch_name, staging_parent_edges.parent_hash AS commit_hash
    FROM shared_history JOIN staging_parent_edges USING (commit_hash)
), branch_points AS (
    SELECT branch_name, commit_hash AS branch_point FROM shared_history
    ANTI JOIN shared_parents USING (branch_name, commit_hash)
)
SELECT tracked_branches.*, branch_points.branch_point, changed_file.* EXCLUDE (repo_path),
       git_uri(tracked_branches.repo_path, changed_file.file_path, branch_points.branch_point) AS before_uri,
       git_uri(tracked_branches.repo_path, changed_file.file_path, tracked_branches.commit_hash) AS after_uri
FROM tracked_branches
JOIN branch_points USING (branch_name)
CROSS JOIN LATERAL git_diff_tree_each(tracked_branches.repo_path, branch_points.branch_point, tracked_branches.commit_hash) changed_file;

-- git's own line counts: one `git diff --numstat` per branch range, rendered by tera from branch_diff into one
-- bash program and written to raw/numstat/<branch_point>/<commit_hash>.tsv. A range never changes, so only
-- ranges without a file are rendered; rerunning these two statements picks up moved branches.
COPY (
    WITH ranges AS (
        SELECT DISTINCT branch_point, commit_hash,
               getenv('HOME') || '/.duck/raw/numstat/' || branch_point || '/' || commit_hash || '.tsv' AS numstat_path
        FROM branch_diff
    )
    SELECT tera_render($tpl$set -e
{% for r in ranges %}mkdir -p {{ root }}/{{ r.branch_point }}
git -C {{ repo }} diff --numstat --no-renames {{ r.branch_point }} {{ r.commit_hash }} > {{ r.numstat_path }}
{% endfor %}echo ranges={{ ranges | length }}
$tpl$, json_object('ranges', coalesce(array_agg(ranges), []), 'root', getenv('HOME') || '/.duck/raw/numstat', 'repo', getenv('HOME') || '/inframe'), autoescape := false)
    FROM ranges WHERE NOT path_exists(numstat_path)
) TO '/Users/aloksubbarao/.duck/raw/numstat.bash' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', DELIMITER '\x01');
FROM read_lines('bash /Users/aloksubbarao/.duck/raw/numstat.bash 2>&1 |', "trim" := true);

-- Every branch_diff file with git's line counts (binary files NULL), both ends' blob metadata and the
-- branch's commit facts. Ahead/behind match `git rev-list --left-right --count origin/staging...<branch>`.
-- A file's blob reads are correlated LATERALs, so WHERE branch_name = … reads only that branch; the side a
-- file lacks gets a NULL uri, because a WHERE inside the LATERAL does not stop the read.
CREATE OR REPLACE VIEW branch_numstat AS
WITH numstat AS (
    SELECT parse_filename(parse_dirpath(filename)) AS branch_point,
           parse_filename(filename, true) AS commit_hash,
           file_path, added_lines, removed_lines
    FROM read_csv(getenv('HOME') || '/.duck/raw/numstat/*/*.tsv', delim := '\t', header := false, nullstr := '-',
                  filename := true, columns := {added_lines: 'BIGINT', removed_lines: 'BIGINT', file_path: 'VARCHAR'})
), staging_log AS (
    SELECT commit_hash FROM git_log('.', 'origin/staging')
), tips AS (
    SELECT DISTINCT branch_name, repo_path, commit_hash AS tip_hash FROM branch_diff
), branch_history AS (
    SELECT tips.branch_name, tips.tip_hash, history.* EXCLUDE (repo_path)
    FROM tips, LATERAL git_log_each(tips.repo_path, tips.tip_hash) history
), branch_facts AS (
    SELECT branch_name,
           count(commit_hash) AS commits_ahead,
           min(author_date) AS first_commit_date,
           max(commit_date) AS last_commit_date,
           count(DISTINCT author_email) AS author_count
    FROM branch_history ANTI JOIN staging_log USING (commit_hash)
    GROUP BY branch_name
), behind AS (
    SELECT tips.branch_name, count(staging_log.commit_hash) AS commits_behind
    FROM tips CROSS JOIN staging_log
    ANTI JOIN branch_history USING (branch_name, commit_hash)
    GROUP BY tips.branch_name
), tip_commits AS (
    SELECT branch_name, author_name AS tip_author_name, author_email AS tip_author_email,
           commit_date AS tip_commit_date, message AS tip_message
    FROM branch_history WHERE commit_hash = tip_hash
), sides AS (
    SELECT branch_diff.*,
           CASE WHEN branch_diff.status <> 'added' THEN branch_diff.before_uri END AS before_side_uri,
           CASE WHEN branch_diff.status <> 'deleted' THEN branch_diff.after_uri END AS after_side_uri
    FROM branch_diff
)
SELECT sides.* EXCLUDE (before_side_uri, after_side_uri),
       numstat.added_lines, numstat.removed_lines,
       numstat.file_path IS NOT NULL AND numstat.added_lines IS NULL AS is_binary,
       before_files.*, after_files.*,
       coalesce(after_files.after_size_bytes, 0) - coalesce(before_files.before_size_bytes, 0) AS size_delta_bytes,
       sides.status = 'modified' AND before_files.before_mode IS DISTINCT FROM after_files.after_mode AS mode_changed,
       branch_facts.* EXCLUDE (branch_name),
       coalesce(behind.commits_behind, 0) AS commits_behind,
       tip_commits.* EXCLUDE (branch_name)
FROM sides
LEFT JOIN LATERAL (
    SELECT blob_hash AS before_blob_hash, mode AS before_mode, is_text AS before_is_text,
           encoding AS before_encoding, size_bytes AS before_size_bytes
    FROM git_read_each(sides.before_side_uri)
) before_files ON true
LEFT JOIN LATERAL (
    SELECT blob_hash AS after_blob_hash, mode AS after_mode, is_text AS after_is_text,
           encoding AS after_encoding, size_bytes AS after_size_bytes
    FROM git_read_each(sides.after_side_uri)
) after_files ON true
LEFT JOIN numstat USING (branch_point, commit_hash, file_path)
LEFT JOIN branch_facts USING (branch_name)
LEFT JOIN behind USING (branch_name)
LEFT JOIN tip_commits USING (branch_name);

-- Definitions each branch_diff file added, removed or modified: sitting_duck parses both ends; a declaration
-- wrapping a same-named definition (TS `const x` around its declarator) is dropped so each name counts once,
-- and the two ends join on qualified_name (scope path with per-name index), not on name.
CREATE OR REPLACE VIEW branch_definition_changes AS
WITH file_sides AS (
    SELECT branch_diff.branch_name, branch_diff.file_path, 'before' AS side, file_read.text
    FROM branch_diff, LATERAL git_read_each(branch_diff.before_uri) file_read
    WHERE branch_diff.status <> 'added'
    UNION ALL
    SELECT branch_diff.branch_name, branch_diff.file_path, 'after' AS side, file_read.text
    FROM branch_diff, LATERAL git_read_each(branch_diff.after_uri) file_read
    WHERE branch_diff.status <> 'deleted'
), nodes AS (
    SELECT branch_name, file_path, side, unnest(parse_ast_list(text, detect_language(file_path)), recursive := true)
    FROM file_sides
    WHERE detect_language(file_path) IS NOT NULL
), definitions AS (
    SELECT * FROM nodes WHERE is_definition(semantic_type) AND name <> ''
), wrapper_definitions AS (
    SELECT parent.branch_name, parent.file_path, parent.side, parent.node_id
    FROM definitions parent JOIN definitions child
      ON child.branch_name = parent.branch_name AND child.file_path = parent.file_path AND child.side = parent.side
     AND child.parent_id = parent.node_id AND child.name = parent.name
), own_definitions AS (
    SELECT * FROM definitions ANTI JOIN wrapper_definitions USING (branch_name, file_path, side, node_id)
), before_definitions AS (
    SELECT * FROM own_definitions WHERE side = 'before'
), after_definitions AS (
    SELECT * FROM own_definitions WHERE side = 'after'
)
SELECT coalesce(after_definitions.branch_name, before_definitions.branch_name) AS branch_name,
       coalesce(after_definitions.file_path, before_definitions.file_path) AS file_path,
       coalesce(after_definitions.qualified_name, before_definitions.qualified_name) AS qualified_name,
       coalesce(after_definitions.name, before_definitions.name) AS name,
       coalesce(after_definitions.type, before_definitions.type) AS node_type,
       CASE WHEN before_definitions.node_id IS NULL THEN 'added'
            WHEN after_definitions.node_id IS NULL THEN 'removed'
            WHEN after_definitions.descendant_count <> before_definitions.descendant_count THEN 'modified'
            WHEN after_definitions.peek <> before_definitions.peek THEN 'modified'
            ELSE 'unchanged' END AS change,
       before_definitions.start_line AS before_start_line, before_definitions.end_line AS before_end_line,
       after_definitions.start_line AS after_start_line, after_definitions.end_line AS after_end_line,
       before_definitions.descendant_count AS before_descendant_count, after_definitions.descendant_count AS after_descendant_count,
       before_definitions.peek AS before_peek, after_definitions.peek AS after_peek
FROM before_definitions FULL JOIN after_definitions
  ON after_definitions.branch_name = before_definitions.branch_name
 AND after_definitions.file_path = before_definitions.file_path
 AND after_definitions.qualified_name = before_definitions.qualified_name;

-- 9494 Quack. 4318 OTLP/HTTP into the otlp_* tables.
FROM quack_serve('quack:localhost:9494', token := getenv('QUACK_TOKEN'));
FROM otlp_serve('otlp:127.0.0.1:4318', disable_auth := true);

-- 9495: POST /sql {"sql": "..."}; POST /inbox any JSON, read it from quackapi_jobs; GET /metrics for Prometheus (/opt/homebrew/etc/prometheus.yml);
-- POST /mcp/ is the dev MCP server: tools query and execute, each a curl to /sql through shellfs, so calls run in parallel.
CREATE QUEUE inbox;
CREATE OR REPLACE ROUTE sql POST '/sql' AS SELECT * FROM quack_query('quack:localhost:9494', $sql, token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE ROUTE inbox POST '/inbox' STATUS 201 AS SELECT quackapi_enqueue('inbox', $body::JSON) AS id;
CREATE OR REPLACE ROUTE metrics GET '/metrics' AS SELECT text FROM meta.prometheus_metrics;
-- A middleware that stops the request sends its body raw as application/json, which is what MCP clients read.
-- The fixed replies are a MAP keyed by method; a tool call's text is the /sql reply (rows, or the DuckDB error).
-- Notifications carry no id and get 202; the body must not be empty or quackapi answers 500.
CREATE GROUP mcp WITH (prefix='/mcp');
CREATE OR REPLACE ROUTE mcp POST '/' IN GROUP mcp AS SELECT '' AS text;
CREATE OR REPLACE MIDDLEWARE mcp BEFORE GROUP mcp AS
WITH msg AS (
    SELECT $body::JSON -> '$.id' AS id, $body::JSON ->> '$.method' AS method
), called AS (  -- a tool call curls /sql through shellfs; the body is a quoted heredoc, so nothing in it is escaped
    FROM msg WHERE method IS DISTINCT FROM 'tools/call'
    UNION ALL BY NAME
    SELECT id, method, json AS reply, json_exists(json, '$.detail') AS failed
    FROM msg, read_json_objects(tera_render($t$curl -s -H 'content-type: application/json' --data-binary @- http://127.0.0.1:9495/sql <<'MCP_BODY'
{{ body }}
MCP_BODY
|$t$, json_object('body', json_object('sql', coalesce($body::JSON ->> '$.params.arguments.sql', $body::JSON ->> '$.params.arguments.statement'))::VARCHAR), autoescape := false), format := 'unstructured')
    WHERE method = 'tools/call'
)
SELECT false AS allow, CASE WHEN id IS NULL THEN 202 ELSE 200 END AS status,
       json_object('jsonrpc', '2.0', 'id', id, 'result', coalesce(
           MAP {'initialize': '{"protocolVersion": "2025-06-18", "serverInfo": {"name": "dev", "version": "1"}, "capabilities": {"tools": {}}}',
                'ping': '{}',
                'tools/list': '{"tools": [{"name": "query", "description": "Run any SQL on dev, reads and writes. Returns the rows as JSON; a failure returns the DuckDB error.", "inputSchema": {"type": "object", "properties": {"sql": {"type": "string"}}, "required": ["sql"]}}, {"name": "execute", "description": "Same as query, for callers that name it execute.", "inputSchema": {"type": "object", "properties": {"statement": {"type": "string"}}, "required": ["statement"]}}]}'}[method]::JSON,
           json_object('content', [json_object('type', 'text', 'text', reply::VARCHAR)], 'isError', failed)))::VARCHAR AS body,
       NULL::VARCHAR AS header_name, NULL::VARCHAR AS header_value
FROM called;
-- query_timeout_ms: a git commit's hooks run ~60 s, past quackapi's 30 s default. Longer work runs backgrounded
-- inside the pipe ('cmd > log 2>&1 & echo $! |') and a later read_lines reads its log.
FROM quackapi_serve(9495, host := '127.0.0.1', query_timeout_ms := 120000);
-- quackapi_serve switches logging off.
CALL enable_logging(['QueryLog', 'HTTP', 'Quack'], storage := 'file', storage_path := getenv('QUACK_NATIVE_LOG'), storage_buffer_size := 0);

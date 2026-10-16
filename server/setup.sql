-- Dev DuckDB. launchd runs `duckdb -bail ~/.duck/db/dev.duckdb -init setup.sql` and keeps stdin open.
-- Dev boots ~/.duck/deploy/server/setup.sql, the duckdb-skills branch `deploy`. A save here changes nothing until
-- it is committed and the branch moved: git branch -f deploy <commit>; the watcher restarts dev within 30 s.
SET GLOBAL extension_directory = '/Users/aloksubbarao/.duck/extensions';
SET GLOBAL secret_directory = '/Users/aloksubbarao/.duck/secrets';
SET GLOBAL temp_directory = '/Users/aloksubbarao/.duck/tmp';
-- DuckDB's performance guide: 1-4 GB per thread. 10 threads x 1.6 GB; RSS runs 1.5-2.5 GB above this
-- (reader/JSON allocations are untracked), and the 48 GB machine keeps ~30 GB for everything else.
SET GLOBAL memory_limit = '16GB';
SET GLOBAL threads = 10;
SET GLOBAL TimeZone = 'UTC';
SET GLOBAL http_retries = 0;

-- INSTALL is a no-op once a file exists, so without this every boot reloads the first build ever downloaded.
-- A child process updates the files before anything below loads them; offline, it prints the error and boot goes on.
INSTALL shellfs FROM community; LOAD shellfs;
SELECT content FROM read_text($u$/opt/homebrew/bin/duckdb -csv :memory: -c "SET extension_directory = '/Users/aloksubbarao/.duck/extensions'; UPDATE EXTENSIONS;" 2>&1; true |$u$);
INSTALL quack; LOAD quack;
INSTALL httpfs; LOAD httpfs;
INSTALL ducklake; LOAD ducklake;
INSTALL cronjob FROM community; LOAD cronjob;
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
INSTALL jsonata FROM community; LOAD jsonata;
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

-- Every branch_diff file with both ends' blob metadata and the branch's commit facts. Ahead/behind match
-- `git rev-list --left-right --count origin/staging...<branch>`. A file's blob reads are correlated LATERALs,
-- so WHERE branch_name = … reads only that branch; the side a file lacks gets a NULL uri, because a WHERE
-- inside the LATERAL does not stop the read.
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

-- 9494 Quack. 4318 OTLP/HTTP into the lake: otlp_serve creates lake.otel.otlp_* (logs, traces, metrics_sum, _gauge,
-- _histogram, _exp_histogram) and commits buffered rows about every 5 s; otlp_stop() commits them, a kill drops them.
-- After its commits it runs CHECKPOINT lake, and it sets the lake's GLOBAL expire_older_than / delete_older_than to
-- maintenance_retention_ms (default 15 min): every lake table's snapshots older than that are expired. 30 days here.
FROM quack_serve('quack:localhost:9494', token := getenv('QUACK_TOKEN'));
CREATE SCHEMA IF NOT EXISTS lake.otel;
FROM otlp_serve('otlp:127.0.0.1:4318', catalog := 'lake', schema := 'otel', disable_auth := true, maintenance_retention_ms := 2592000000);

-- 9495: POST /sql {"sql": "..."}; POST /inbox any JSON, read it from quackapi_jobs; GET /metrics for Prometheus (/opt/homebrew/etc/prometheus.yml);
-- POST /mcp/ is the dev MCP server: tools query and execute, each a curl to /sql through shellfs, so calls run in parallel.
-- The inbox queue (quackapi_jobs) lives in dev.duckdb: jobs still queued are lost when the file is reset.
CREATE QUEUE inbox;
CREATE OR REPLACE ROUTE sql POST '/sql' AS SELECT * FROM quack_query('quack:localhost:9494', $sql, token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE ROUTE inbox POST '/inbox' STATUS 201 AS SELECT quackapi_enqueue('inbox', $body::JSON) AS id;
CREATE OR REPLACE ROUTE metrics GET '/metrics' AS SELECT text FROM meta.prometheus_metrics;
-- GET /profile?sql=…: the query graph that `python -m duckdb.query_graph` draws. Runs the SQL (writes included) under
-- EXPLAIN (ANALYZE, FORMAT json) through Quack, keeps the profile as ~/.duck/logs/profiles/<UTC time>.json (a COPY
-- dispatched to /sql), and answers one HTML page: headline metrics, time per operator type, and the operator tree in
-- preorder with each node's share of operator time. jsonata walks the children; the EXPLAIN_ANALYZE wrapper is skipped.
-- Thousands separators come from printf('%,d'): dev's catalog has a two-argument main.format(fmt, val) macro that
-- shadows DuckDB's format('{:,}', n) and fails on numbers.
SELECT content FROM read_text('mkdir -p /Users/aloksubbarao/.duck/logs/profiles |');
CREATE OR REPLACE ROUTE profile GET '/profile' AS
WITH run AS (
    SELECT explain_value::JSON AS profile, '/Users/aloksubbarao/.duck/logs/profiles/' || strftime(now(), '%Y%m%dT%H%M%S.%fZ') || '.json' AS path
    FROM quack_query('quack:localhost:9494', 'EXPLAIN (ANALYZE, FORMAT json) ' || $sql, token := getenv('QUACK_TOKEN'))
), saved AS (
    SELECT *, http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql',
               printf($c$COPY (SELECT $profile$%s$profile$) TO '%s' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '')$c$, profile, path))) ->> '$.status' AS saved_status
    FROM run
), node AS (
    SELECT profile, path, saved_status, unnest(from_json(jsonata($j$(
        $walk := function($n, $d) { $n.operator_type = "EXPLAIN_ANALYZE" ? $n.children.$walk($, $d) :
            [{"name": $n.operator_name, "depth": $d, "seconds": $n.operator_timing, "card": $n.operator_cardinality,
              "scanned": $n.operator_rows_scanned, "est": $n.extra_info.`Estimated Cardinality`,
              "extra": [$each($sift($n.extra_info, function($v, $k) { $k != "Estimated Cardinality" }), function($v, $k) { $k & ": " & $join([$v], ", ") })]},
             $n.children.$walk($, $d + 1)] };
        $map([children.$walk($, 0)], function($n, $i) { $merge([{"idx": $i}, $n]) })
    )$j$, profile), '[{"idx": "INTEGER", "name": "VARCHAR", "depth": "INTEGER", "seconds": "DOUBLE", "card": "UBIGINT", "scanned": "UBIGINT", "est": "VARCHAR", "extra": ["VARCHAR"]}]'), recursive := true)
    FROM saved
), share AS (
    SELECT *, seconds / sum(seconds) OVER () AS part FROM node
), phase AS (
    SELECT profile, path, saved_status, name, sum(seconds) AS seconds, sum(part) AS part, count(idx) AS nodes,
           list({idx: idx, name: name, indent: depth * 18, seconds: printf('%.6f', seconds), pct: printf('%.1f%%', part * 100),
                 card: printf('%,d', card), est: coalesce(est, '?'), scanned: printf('%,d', scanned), extra: coalesce(extra, []), hot: part >= 0.25}) AS members
    FROM share GROUP BY ALL
)
SELECT tera_render($t$<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Query profile</title><style>
:root{--bg:#fafaf7;--card:#fff;--ink:#1c1c19;--mute:#6b6a62;--line:#e3e1d8;--hot:#d97706;--bar:#f6e3c3;--mono:ui-monospace,SFMono-Regular,Menlo,monospace}
@media (prefers-color-scheme: dark){:root:not([data-theme="light"]){--bg:#121210;--card:#1b1b18;--ink:#ecebe4;--mute:#a3a299;--line:#34332e;--hot:#f59e0b;--bar:#4a3410}}
:root[data-theme="dark"]{--bg:#121210;--card:#1b1b18;--ink:#ecebe4;--mute:#a3a299;--line:#34332e;--hot:#f59e0b;--bar:#4a3410}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 system-ui,-apple-system,sans-serif}
main{max-width:980px;margin:0 auto;padding:24px 16px}h1{font-size:22px;margin:0 0 8px}h2{font-size:16px;margin:28px 0 8px}
code,pre,.m,td{font-family:var(--mono)}code{font-size:13px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:10px;margin:16px 0}
.card{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:10px 12px}
.card b{display:block;font-size:11px;color:var(--mute);font-weight:500;text-transform:uppercase;letter-spacing:.05em}.card span{font:600 17px var(--mono)}
pre{background:var(--card);border:1px solid var(--line);border-radius:8px;padding:12px;overflow-x:auto;font-size:13px;white-space:pre-wrap}
table{width:100%;border-collapse:collapse;font-size:13px;font-variant-numeric:tabular-nums}
th,td{padding:5px 8px;border-bottom:1px solid var(--line);text-align:right}th:first-child,td:first-child{text-align:left}th{color:var(--mute);font-weight:500}
.tree{overflow-x:auto;padding-bottom:8px}
.op{border-left:3px solid var(--line);margin:3px 0;padding:6px 10px;border-radius:4px;min-width:260px;
    background:linear-gradient(90deg,var(--bar) var(--share),var(--card) var(--share));box-shadow:inset 0 0 0 1px var(--line)}
.op.hot{border-left-color:var(--hot)}.op .n{font-weight:600}.m{font-size:12px;color:var(--mute)}
details summary{cursor:pointer;color:var(--mute);font-size:12px}.hot-text{color:var(--hot);font-weight:600}
</style></head><body><main>
{% set top = phases | first %}<h1>Query profile</h1>
<p><span class="hot-text">{{ top.name }}</span> takes {{ top.pct }} of operator CPU time ({{ top.seconds }} s of {{ cpu }} s, summed over threads, across {{ nodes | length }} operators);
the query ran {{ latency }} s end to end. {% if saved == "200" %}Profile saved to <code>{{ path }}</code>.{% else %}The profile was not saved (status {{ saved }}).{% endif %}</p>
<section class="grid">{% for c in cards %}<div class="card"><b>{{ c.t }}</b><span>{{ c.v }}</span></div>{% endfor %}</section>
<details><summary>SQL</summary><pre>{{ sql }}</pre></details>
<h2>Time by operator</h2><table><tr><th>Operator</th><th>Nodes</th><th>Seconds</th><th>Share</th></tr>
{% for p in phases %}<tr><td>{{ p.name }}</td><td>{{ p.nodes }}</td><td>{{ p.seconds }}</td><td>{{ p.pct }}</td></tr>{% endfor %}</table>
<h2>Operator tree</h2><div class="tree">{% for n in nodes %}
<div class="op{% if n.hot %} hot{% endif %}" style="margin-left:{{ n.indent }}px;--share:{{ n.pct }}"><span class="n">{{ n.name }}</span>
<span class="m">{{ n.seconds }} s · {{ n.pct }} · {{ n.card }} rows · est {{ n.est }}{% if n.scanned != "0" %} · scanned {{ n.scanned }}{% endif %}</span>
{% if n.extra %}<details><summary>extra info</summary><div class="m">{% for e in n.extra %}{{ e }}<br>{% endfor %}</div></details>{% endif %}</div>{% endfor %}
</div></main></body></html>$t$, json_object(
    'sql', $sql, 'path', path, 'saved', saved_status, 'cpu', printf('%.4f', sum(seconds)),
    'latency', printf('%.4f', (profile ->> 'latency')::DOUBLE),
    'phases', list({name: name, nodes: nodes, seconds: printf('%.6f', seconds), pct: printf('%.1f%%', part * 100)} ORDER BY seconds DESC),
    'nodes', list_sort(flatten(list(members))),
    'cards', [{t: 'Latency', v: printf('%.4f s', (profile ->> 'latency')::DOUBLE)},
              {t: 'Operator CPU', v: printf('%.4f s', sum(seconds))},
              {t: 'Rows scanned', v: printf('%,d', (profile ->> 'cumulative_rows_scanned')::BIGINT)},
              {t: 'Read', v: format_bytes((profile ->> 'total_bytes_read')::BIGINT)},
              {t: 'Written', v: format_bytes((profile ->> 'total_bytes_written')::BIGINT)},
              {t: 'Peak buffer memory', v: format_bytes((profile ->> 'system_peak_buffer_memory')::BIGINT)},
              {t: 'Peak temp dir', v: format_bytes((profile ->> 'system_peak_temp_dir_size')::BIGINT)},
              {t: 'Memory allocated', v: format_bytes((profile ->> 'total_memory_allocated')::BIGINT)}])) AS html
FROM phase GROUP BY profile, path, saved_status;
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
-- Response cap 64 MiB (default 16): one transcript line reaches 21 MB; 32 parallel replies stay under 2 GiB.
-- Bigger self-dispatch reads write Parquet on dev and return a count.
SET GLOBAL quackapi_max_response_bytes = 67108864;
FROM quackapi_serve(9495, host := '127.0.0.1', query_timeout_ms := 120000);
-- quackapi_serve switches logging off.
CALL enable_logging(['QueryLog', 'HTTP', 'Quack'], storage := 'file', storage_path := getenv('QUACK_NATIVE_LOG'), storage_buffer_size := 0);
-- Agent transcripts (Claude Code ~/.claude/projects, Codex ~/.codex), typed once into Parquet, one partition per
-- transcript: ~/.duck/lake/agent/project=<folder under projects/>/key=<rest of its path>/data_0.parquet (Codex: project
-- '.codex', key = the file name without .zst: a session moves to archived_sessions/ and is compressed in place).
-- agent.files: one find, hostfs columns on its rows.
CREATE SCHEMA IF NOT EXISTS agent;
CREATE OR REPLACE VIEW agent.files AS
SELECT path, parse_dirpath(path) AS parent, file_name(path) AS name, path_split(path) AS parts, file_size(path) AS bytes,
       file_last_modified(path) AS modified
FROM (SELECT rtrim(content, e'\n') AS path
      FROM read_lines($c$find ~/.claude/projects ~/.codex/sessions ~/.codex/archived_sessions -type f -name '*.jsonl*' |$c$));
-- One COPY per transcript: read_text (.zst through scalarfs's decompress+zstd:), its lines numbered (unnest +
-- generate_subscripts in the select list: a CROSS JOIN UNNEST carries the whole file into every line's row), every line
-- typed by one shape (bad = a line that is not JSON), OVERWRITE_OR_IGNORE replacing its data_0.parquet. Boot replaces
-- every transcript, the cron every 5 minutes those modified since yesterday (so a session's last lines before midnight
-- land), each run as 4 /sql bodies that run their statements in order: 4 files in memory at a time.
CREATE OR REPLACE VIEW agent.ingest AS
SELECT path, modified, printf($s$
COPY (
    SELECT '%s' AS project, '%s' AS key, '%s' AS file, line, record, bad, j,
           coalesce(j.sessionId, j.session_id, CASE project WHEN '.codex' THEN right(replace(key, '.jsonl', ''), 36) END) AS session_id,
           j.agentId AS agent_id, j.type, j.payload.type AS payload_type, TRY_CAST(j.timestamp AS TIMESTAMPTZ) AS ts,
           coalesce(j.promptId, j.payload.turn_id, j.payload.internal_chat_message_metadata_passthrough.turn_id) AS turn_id,
           CASE json_type(record, '$.message.content') WHEN 'VARCHAR' THEN record ->> '$.message.content' END AS message_text
    FROM (SELECT line, CASE WHEN json_valid(text) THEN text::JSON END AS record,
                 CASE WHEN record IS NULL THEN text END AS bad, json_transform(record, '{
                  "type": "VARCHAR", "subtype": "VARCHAR", "timestamp": "VARCHAR", "sessionId": "VARCHAR", "session_id": "VARCHAR",
                  "agentId": "VARCHAR", "promptId": "VARCHAR", "requestId": "VARCHAR", "cwd": "VARCHAR", "gitBranch": "VARCHAR", "version": "VARCHAR",
                  "message": {"id": "VARCHAR", "model": "VARCHAR", "stop_reason": "VARCHAR",
                      "usage": {"input_tokens": "BIGINT", "cache_read_input_tokens": "BIGINT", "cache_creation_input_tokens": "BIGINT", "output_tokens": "BIGINT"},
                      "content": [{"type": "VARCHAR", "text": "VARCHAR", "thinking": "VARCHAR", "signature": "VARCHAR", "id": "VARCHAR", "name": "VARCHAR",
                                   "input": "JSON", "tool_use_id": "VARCHAR", "is_error": "BOOLEAN", "content": "JSON"}]},
                  "payload": {"type": "VARCHAR", "turn_id": "VARCHAR", "role": "VARCHAR", "model": "VARCHAR", "cwd": "VARCHAR", "cli_version": "VARCHAR",
                      "parent_thread_id": "VARCHAR", "forked_from_id": "VARCHAR", "git": {"branch": "VARCHAR"},
                      "internal_chat_message_metadata_passthrough": {"turn_id": "VARCHAR"},
                      "call_id": "VARCHAR", "name": "VARCHAR", "namespace": "VARCHAR", "arguments": "VARCHAR", "input": "JSON", "output": "JSON",
                      "response_id": "VARCHAR", "started_at_ms": "BIGINT", "completed_at_ms": "BIGINT", "encrypted_content": "VARCHAR",
                      "content": [{"type": "VARCHAR", "text": "VARCHAR"}], "summary": [{"text": "VARCHAR"}],
                      "usage": {"input_tokens": "BIGINT", "cached_input_tokens": "BIGINT", "cache_write_input_tokens": "BIGINT", "output_tokens": "BIGINT",
                                "reasoning_output_tokens": "BIGINT"},
                      "info": {"last_token_usage": {"input_tokens": "BIGINT", "cached_input_tokens": "BIGINT", "cache_write_input_tokens": "BIGINT",
                                                    "output_tokens": "BIGINT", "reasoning_output_tokens": "BIGINT"}},
                      "item": {"id": "VARCHAR", "type": "VARCHAR", "tool": "VARCHAR", "server": "VARCHAR", "status": "VARCHAR", "exit_code": "BIGINT",
                               "arguments": "JSON", "command": "JSON", "changes": "JSON", "prompt": "JSON", "result": "JSON", "error": "JSON",
                               "aggregated_output": "JSON", "stdout": "JSON"}}}') AS j
          FROM (SELECT unnest(parts) AS text, generate_subscripts(parts, 1) AS line
                FROM (SELECT string_split(content, e'\n')[:-2] AS parts FROM read_text('%s'))))   -- [:-2]: after the last newline
) TO '~/.duck/lake/agent' (FORMAT parquet, PARTITION_BY (project, key), OVERWRITE_OR_IGNORE, ROW_GROUP_SIZE 2048)
$s$, coalesce(parts[p + 1], '.codex'), CASE WHEN p IS NULL THEN replace(name, '.zst', '') ELSE list_aggr(parts[p + 2:], 'string_agg', '/') END,
     path, CASE WHEN ends_with(name, '.zst') THEN 'decompress+zstd:' || path ELSE path END) AS stmt
FROM (SELECT *, list_position(parts, 'projects') AS p FROM agent.files);
SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', string_agg(stmt, e';\n'))).status FROM agent.ingest GROUP BY hash(path) % 4;
SELECT cron($$SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', string_agg(stmt, e';\n'))).status
FROM agent.ingest WHERE modified >= current_date - INTERVAL 1 DAY GROUP BY hash(path) % 4$$, '0 */5 * * * *');

-- One row per transcript line: record = the whole line, j = it typed, plus its top-level fields.
CREATE OR REPLACE VIEW agent.lines AS
SELECT CASE project WHEN '.codex' THEN 'codex' ELSE 'claude' END AS source, * EXCLUDE (project, key)
FROM read_parquet('~/.duck/lake/agent/*/*/data_0.parquet', hive_partitioning := true);
-- The same view in the lake, for any process that attaches it.
CREATE SCHEMA IF NOT EXISTS lake.agent;
CREATE OR REPLACE VIEW lake.agent.lines AS
SELECT CASE project WHEN '.codex' THEN 'codex' ELSE 'claude' END AS source, * EXCLUDE (project, key)
FROM read_parquet('/Users/aloksubbarao/.duck/lake/agent/*/*/data_0.parquet', hive_partitioning := true);
-- One row per tool call with its result: the next result line with the same call id in the same file. level 'model' =
-- a call the model issued (Claude tool_use; Codex function_call / custom_tool_call / tool_search_call), paired with an
-- output, never with the completed item that shares its id; 'nested' = Codex work inside a model call (one completed item
-- is its own result), parent_call_id = the model call before it. turn_id =
-- the last turn marker at or before the call; Codex response_id = the next usage record's. is_error: Claude's flag;
-- Codex nested from the item's status / exit code; Codex model calls NULL. error = the whole result of a failed call; any
-- other result body is agent.lines at (file, result_line). est_tokens = (input + result bytes) / 4.
CREATE OR REPLACE VIEW agent.tool_calls AS
WITH ev AS (
    SELECT source, file, line, ts, session_id, agent_id, 'model' AS level, j.message.id AS response_id, b.type = 'tool_use' AS is_call,
           b.type = 'tool_result' AS is_result, coalesce(b.id, b.tool_use_id) AS call_id, b.name AS tool_name, b.input,
           strlen(b.content::VARCHAR) AS result_bytes, b.is_error, CASE WHEN b.is_error THEN b.content END AS error
    FROM agent.lines CROSS JOIN UNNEST(j.message.content) AS u(b) WHERE b.type IN ('tool_use', 'tool_result')
    UNION ALL BY NAME
    SELECT source, file, line, ts, session_id, 'model' AS level, ends_with(payload_type, '_call') AS is_call,
           ends_with(payload_type, '_output') AS is_result,
           j.payload.call_id, j.payload.name AS tool_name, j.payload.namespace, coalesce(TRY_CAST(j.payload.arguments AS JSON), j.payload.input) AS input,
           strlen(j.payload.output::VARCHAR) AS result_bytes
    FROM agent.lines
    WHERE payload_type IN ('function_call', 'custom_tool_call', 'tool_search_call', 'function_call_output', 'custom_tool_call_output', 'tool_search_output')
    UNION ALL BY NAME
    SELECT source, file, line, ts, session_id, true AS is_call, true AS is_result, 'nested' AS level, i.id AS call_id,
           coalesce(i.tool, i.type) AS tool_name, coalesce(i.server, i.type) AS namespace, coalesce(i.arguments, i.command, i.changes, i.prompt) AS input,
           strlen(coalesce(i.result, i.error, i.aggregated_output, i.stdout)::VARCHAR) AS result_bytes,
           CASE i.status WHEN 'completed' THEN coalesce(i.exit_code, 0) <> 0 ELSE i.status IS NOT NULL END AS is_error,
           CASE WHEN is_error THEN coalesce(i.error, i.result, i.aggregated_output, i.stdout) END AS error,
           j.payload.completed_at_ms - j.payload.started_at_ms AS item_ms
    FROM (SELECT *, j.payload.item AS i FROM agent.lines WHERE payload_type = 'item_completed')
    WHERE i.type IN ('CommandExecution', 'McpToolCall', 'FileChange', 'DynamicToolCall', 'CollabAgentToolCall', 'Extension', 'ImageView', 'SubAgentActivity')
), model AS (FROM ev WHERE is_call AND level = 'model'
), turns AS (SELECT file, line, turn_id FROM agent.lines WHERE turn_id IS NOT NULL
), usage AS (SELECT file, line, j.payload.response_id FROM agent.lines WHERE type = 'token_usage_record'
)
SELECT c.source, c.level, c.session_id, c.agent_id, t.turn_id, c.file, c.line, c.ts,
       coalesce(c.response_id, u.response_id) AS response_id, c.call_id, p.call_id AS parent_call_id, c.tool_name, c.namespace, c.input,
       strlen(c.input::VARCHAR) AS input_bytes, r.line AS result_line, r.ts AS result_ts, r.result_bytes,
       (coalesce(input_bytes, 0) + coalesce(r.result_bytes, 0)) // 4 AS est_tokens, r.is_error, r.error,
       coalesce(c.item_ms, date_diff('millisecond', c.ts, r.ts)) AS duration_ms
FROM (FROM ev WHERE is_call) c
ANTI JOIN model m ON c.level = 'nested' AND m.file = c.file AND m.call_id = c.call_id   -- a model call's own completion item
ASOF LEFT JOIN (FROM ev WHERE is_result) r ON r.file = c.file AND r.call_id = c.call_id AND r.level = c.level AND r.line >= c.line
ASOF LEFT JOIN model p ON c.level = 'nested' AND p.file = c.file AND p.line < c.line
ASOF LEFT JOIN turns t ON t.file = c.file AND t.line <= c.line
ASOF LEFT JOIN usage u ON u.file = c.file AND u.line > c.line;
-- One row per API response. Claude: the last line of each message.id in a file (usage repeats on every block line and
-- the last has the final counts). Codex: token_usage_record; files without any fall back to token_count's
-- last_token_usage (never the cumulative totals); model = the turn_context before it. total_input_tokens is comparable
-- across sources (Claude input + cache read + cache write; Codex input already includes cached).
CREATE OR REPLACE VIEW agent.usage AS
WITH claude AS (
    SELECT source, file, line, ts, session_id, agent_id, j.message.id AS response_id, j.requestId AS request_id, j.message.model AS model,
           j.message.stop_reason, j.message.usage AS u
    FROM agent.lines WHERE type = 'assistant' AND j.message.id IS NOT NULL
), codex AS (
    SELECT source, file, line, ts, session_id, coalesce(payload_type, type) AS kind, j.payload.response_id,
           coalesce(j.payload.usage, j.payload.info.last_token_usage) AS u
    FROM agent.lines WHERE coalesce(payload_type, type) IN ('token_usage_record', 'token_count')
), turns AS (SELECT file, line, turn_id FROM agent.lines WHERE turn_id IS NOT NULL
), models AS (SELECT file, line, j.payload.model FROM agent.lines WHERE payload_type = 'turn_context'
)
SELECT a.source, a.file, a.line, a.ts, a.session_id, a.agent_id, t.turn_id, a.response_id, a.request_id, a.model, a.stop_reason,
       a.u.input_tokens + a.u.cache_read_input_tokens + a.u.cache_creation_input_tokens AS total_input_tokens,
       a.u.cache_read_input_tokens AS cache_read_tokens, a.u.cache_creation_input_tokens AS cache_write_tokens, a.u.output_tokens,
       NULL::BIGINT AS reasoning_tokens
FROM claude a
ANTI JOIN claude b ON b.file = a.file AND b.response_id = a.response_id AND b.line > a.line
ASOF LEFT JOIN turns t ON t.file = a.file AND t.line <= a.line
UNION ALL
SELECT x.source, x.file, x.line, x.ts, x.session_id, NULL, t.turn_id, x.response_id, NULL, m.model, NULL, x.u.input_tokens,
       x.u.cached_input_tokens, x.u.cache_write_input_tokens, x.u.output_tokens, x.u.reasoning_output_tokens
FROM codex x
ANTI JOIN (FROM codex WHERE kind = 'token_usage_record') r ON x.kind = 'token_count' AND r.file = x.file
ASOF LEFT JOIN turns t ON t.file = x.file AND t.line <= x.line
ASOF LEFT JOIN models m ON m.file = x.file AND m.line <= x.line
WHERE x.u IS NOT NULL;
-- Resumed/forked sessions copy earlier lines into a new file, so a call or response appears in several files.
-- first_seen marks the earliest copy: sum tokens and bytes WHERE first_seen.
CREATE OR REPLACE VIEW agent.copies AS
SELECT kind, source, id, file, line, row_number() OVER (PARTITION BY kind, source, id ORDER BY ts, file, line) = 1 AS first_seen
FROM (SELECT 'tool_call' AS kind, source, call_id AS id, file, line, ts FROM agent.tool_calls
      UNION ALL
      SELECT 'response', source, response_id, file, line, ts FROM agent.usage)
WHERE id IS NOT NULL;
-- Visible text: Claude text blocks (a string content is one block); Codex message / agent_message content parts.
CREATE OR REPLACE VIEW agent.messages AS
SELECT source, file, line, b.idx, session_id, agent_id, ts, type AS role, b.block.text
FROM agent.lines CROSS JOIN UNNEST(j.message.content) WITH ORDINALITY AS b(block, idx) WHERE b.block.type = 'text'
UNION ALL
SELECT source, file, line, 1, session_id, agent_id, ts, type, message_text FROM agent.lines WHERE message_text IS NOT NULL
UNION ALL
SELECT source, file, line, b.idx, session_id, agent_id, ts, coalesce(j.payload.role, 'agent'), b.part.text
FROM agent.lines CROSS JOIN UNNEST(j.payload.content) WITH ORDINALITY AS b(part, idx) WHERE payload_type IN ('message', 'agent_message');
-- Claude thinking blocks (text empty when redacted); Codex reasoning summary parts. Encrypted bodies stay in record.
CREATE OR REPLACE VIEW agent.thinking AS
SELECT source, file, line, b.idx, session_id, agent_id, ts, j.message.id AS response_id, b.block.thinking AS text,
       strlen(b.block.signature) AS opaque_bytes
FROM agent.lines CROSS JOIN UNNEST(j.message.content) WITH ORDINALITY AS b(block, idx) WHERE b.block.type IN ('thinking', 'redacted_thinking')
UNION ALL
SELECT source, file, line, s.idx, session_id, agent_id, ts, NULL, s.part.text, strlen(j.payload.encrypted_content)
FROM agent.lines CROSS JOIN UNNEST(coalesce(nullif(j.payload.summary, []), [NULL])) WITH ORDINALITY AS s(part, idx)
WHERE payload_type = 'reasoning';
-- What Claude's harness injected (Codex has no attachment records).
CREATE OR REPLACE VIEW agent.attachments AS
SELECT file, line, session_id, agent_id, ts, record ->> '$.attachment.type' AS kind, record ->> '$.attachment.hookEvent' AS hook_event,
       record ->> '$.attachment.toolUseID' AS tool_use_id, record -> '$.attachment' AS attachment, record -> '$.rendered' AS rendered
FROM agent.lines WHERE type = 'attachment';
-- Every line the views above do not read, whole record kept (Claude system/*, queue and session-state records;
-- Codex session_meta, turn_context, task and compaction events, ...).
CREATE OR REPLACE VIEW agent.system_events AS
SELECT source, file, line, session_id, ts, turn_id, type, payload_type, j.subtype, record
FROM agent.lines
WHERE type NOT IN ('user', 'assistant', 'attachment', 'token_usage_record')
  AND coalesce(payload_type, '') NOT IN ('message', 'agent_message', 'reasoning', 'function_call', 'custom_tool_call', 'tool_search_call',
        'function_call_output', 'custom_tool_call_output', 'tool_search_output', 'token_count', 'item_completed');
-- Where and as what each transcript ran, from its user / session_meta lines: one row per distinct combination (a
-- session that changes folder or version has several). Titles are ai-title / custom-title records in agent.system_events.
CREATE OR REPLACE VIEW agent.sessions AS
SELECT DISTINCT source, file, session_id, agent_id, contains(file, '/subagents/') AS is_subagent, coalesce(j.cwd, j.payload.cwd) AS cwd,
       coalesce(j.gitBranch, j.payload.git.branch) AS git_branch, coalesce(j.version, j.payload.cli_version) AS version,
       j.payload.parent_thread_id AS parent_session_id, j.payload.forked_from_id AS forked_from_id
FROM agent.lines WHERE type IN ('user', 'session_meta');

-- One row per tool call over agent.tool_calls, with what it ran: programs is what the bash ran, including commands
-- inside shellfs pipes in SQL; functions is what the SQL called; error = the whole result of a failed call. sitting_duck
-- parses every call it returns, so filter source and ts. Resumed/forked transcripts repeat calls; agent.copies
-- (kind = 'tool_call', first_seen) marks the first copy.
CREATE OR REPLACE VIEW agent.tool_call_analysis AS
WITH c AS (
    SELECT source, call_id, level, session_id, file AS transcript, ts, tool_name AS tool, input, error, result_bytes
    FROM agent.tool_calls
), parsed AS (
    SELECT source, call_id, c.level, c.session_id, c.transcript, c.ts, c.tool, c.input,
           c.input ->> 'command' AS command,
           coalesce(c.input ->> 'sql', c.input ->> 'statement') AS sql,
           parse_ast_list(sql, 'sql') AS sql_ast,
           list_transform(list_filter(sql_ast, lambda n: n.type = 'literal'),
                          lambda n: CASE WHEN starts_with(n.name, '$') THEN string_split(n.name, '$' || string_split(n.name, '$')[2] || '$')[2] ELSE trim(n.name, $q$'$q$) END) AS literals,
           list_transform(list_filter(literals, lambda s: ends_with(rtrim(s), '|')), lambda s: rtrim(rtrim(s), '|')) AS pipes,
           list_distinct(flatten(list_transform(list_prepend(command, pipes), lambda p: list_transform(list_filter(parse_ast_list(p, 'bash'), lambda n: n.type = 'command_name'), lambda n: n.peek)))) AS programs,
           list_distinct(list_transform(list_filter(sql_ast, lambda n: n.type = 'invocation'), lambda n: lower(n.name))) AS functions,
           c.error, c.result_bytes
    FROM c
)
SELECT * EXCLUDE (command, sql, sql_ast, literals, pipes) FROM parsed;

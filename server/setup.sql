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

-- Agent transcripts (Claude Code ~/.claude/projects, Codex ~/.codex), read natively, one Parquet per transcript at its own
-- path under ~/.duck/lake/agent.
-- agent.entries: PR #1576's entries shape over one find: hostfs columns, the file's reader and the statement that reads
-- it. read_json infers every field and type from the file, three levels deep (Claude's message.role / model / id typed;
-- anything deeper, tool inputs and results among it, stays JSON). Objects with over 200 distinct keys become MAPs: keyed
-- by tool-call id or file path, they would otherwise be thousands of columns (a 445K-character type that ran dev out of
-- memory on one 326 MB transcript); Codex's payload, a union of event types, is MAP(VARCHAR, JSON). maximum_object_size
-- 32 MB fits the largest line (~21 MB); the reader's buffers are twice it per thread.
CREATE SCHEMA IF NOT EXISTS agent;
CREATE OR REPLACE VIEW agent.entries AS
SELECT path, parse_dirpath(path) AS parent, file_name(path) AS name, file_extension(path) AS ext, file_size(path) AS bytes,
       file_last_modified(path) AS modified, 'read_json' AS reader,
       printf($s$SELECT * FROM read_json('%s', format := 'newline_delimited', maximum_depth := 3, sample_size := -1,
           maximum_object_size := 33554432, ignore_errors := true)$s$, path) AS sql_statement,
       '~/.duck/lake/agent' || path || '.parquet' AS stored
FROM (SELECT rtrim(content, e'\n') AS path
      FROM read_lines($c$find ~/.claude/projects ~/.codex/sessions ~/.codex/archived_sessions -type f -name '*.jsonl*' |$c$));
-- Each entry's statement, copied to its stored file. Boot copies every transcript; every 5 minutes the cron copies those
-- modified since yesterday. A run is 4 /sql bodies that each run in order: 4 files in memory at a time.
CREATE OR REPLACE VIEW agent.ingest AS
SELECT path, parent, modified, printf($s$COPY (%s) TO '%s' (FORMAT parquet)$s$, sql_statement, stored) AS stmt FROM agent.entries;
SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', printf($s$SELECT content FROM read_text('mkdir -p %s |')$s$,
           string_agg(DISTINCT '~/.duck/lake/agent' || parent, ' ')) || e';\n' || string_agg(stmt, e';\n'))).status
FROM agent.ingest GROUP BY hash(path) % 4;
SELECT cron($$SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', printf($s$SELECT content FROM read_text('mkdir -p %s |')$s$,
           string_agg(DISTINCT '~/.duck/lake/agent' || parent, ' ')) || e';\n' || string_agg(stmt, e';\n'))).status
FROM agent.ingest WHERE modified >= current_date - INTERVAL 1 DAY GROUP BY hash(path) % 4$$, '0 */5 * * * *');
-- Every stored transcript whose source still exists (a Codex session compressed or archived leaves its old copy behind).
CREATE OR REPLACE VIEW agent.lines AS
SELECT * FROM (SELECT *, split_part(filename, '/.duck/lake/agent', 2)[:-9] AS transcript   -- Claude records have their own source
               FROM read_parquet('~/.duck/lake/agent/**/*.parquet', union_by_name := true, filename := true))
SEMI JOIN agent.entries e ON e.path = transcript;

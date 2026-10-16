-- Dev DuckDB. launchd runs `duckdb -bail ~/.duck/db/dev.duckdb -init setup.sql` and keeps stdin open.
-- Dev boots ~/.duck/deploy/server/setup.sql, the duckdb-skills branch `deploy`. A save here changes nothing until
-- it is committed and the branch moved: git branch -f deploy <commit>; the watcher restarts dev within 30 s.
SET GLOBAL extension_directory = '~/.duck/extensions';
SET GLOBAL secret_directory = '~/.duck/secrets';
SET GLOBAL temp_directory = '~/.duck/tmp';
-- DuckDB's performance guide: 1-4 GB per thread. 10 threads x 1.6 GB; RSS runs 1.5-2.5 GB above this
-- (reader/JSON allocations are untracked), and the 48 GB machine keeps ~30 GB for everything else.
SET GLOBAL memory_limit = '16GB';
SET GLOBAL threads = 10;
SET GLOBAL TimeZone = 'UTC';
SET GLOBAL http_retries = 0;

-- INSTALL is a no-op once a file exists, so without this every boot reloads the first build ever downloaded.
-- A child process updates the files before anything below loads them; offline, it prints the error and boot goes on.
INSTALL shellfs FROM community; LOAD shellfs;
SELECT content FROM read_text($u$/opt/homebrew/bin/duckdb -csv :memory: -c "SET extension_directory = '~/.duck/extensions'; UPDATE EXTENSIONS;" 2>&1; true |$u$);
INSTALL quack; LOAD quack;
INSTALL httpfs; LOAD httpfs;
INSTALL ducklake; LOAD ducklake;
INSTALL cronjob FROM community; LOAD cronjob;
INSTALL hostfs FROM community; LOAD hostfs;
INSTALL http_client FROM community; LOAD http_client;
INSTALL read_lines FROM community; LOAD read_lines;
INSTALL agent_data FROM community; LOAD agent_data;
INSTALL quackapi FROM community; LOAD quackapi;
-- Used by the agents.ext_* docs views.
INSTALL webbed FROM community; LOAD webbed;
INSTALL markdown FROM community; LOAD markdown;
INSTALL urlpattern FROM community; LOAD urlpattern;
INSTALL otlp FROM community; LOAD otlp;
-- sazgar is intentionally not installed: community-extensions has no
-- linux_amd64 build published for DuckDB 1.5.5 (HTTP 404 on a fresh home),
-- and nothing in this boot uses it since the prometheus view was dropped.
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
SELECT content FROM read_text('mkdir -p ' || getenv('HOME') || '/inframe && echo ok |') LIMIT 1;
FROM cd(getenv('HOME') || '/inframe');

CALL enable_logging(['QueryLog', 'HTTP', 'Quack', 'Metrics'], storage := 'file', storage_path := getenv('QUACK_NATIVE_LOG'), storage_buffer_size := 0);
-- Profiling is per connection (enable_profiling cannot be SET GLOBAL), so each connection that should report runs this
-- CALL itself: this boot connection and the CHECKPOINT cron below. Every profiled statement then logs one 'Metrics' row
-- per metric (meta.query_metrics); 'no_output' prints nothing. Quack and quackapi request connections start with
-- profiling off. ROWS_RETURNED stays out: on DuckDB 1.5.6 it is NULL, and a NULL metric in a JSON profile
-- (EXPLAIN (ANALYZE, FORMAT json)) is an internal error that invalidates the database.
CALL enable_profiling(format := 'no_output', coverage := 'all',
     metrics := ['LATENCY', 'CPU_TIME', 'BLOCKED_THREAD_TIME', 'RESULT_SET_SIZE', 'CUMULATIVE_ROWS_SCANNED', 'SYSTEM_PEAK_BUFFER_MEMORY',
                 'SYSTEM_PEAK_TEMP_DIR_SIZE', 'TOTAL_MEMORY_ALLOCATED', 'TOTAL_BYTES_READ', 'TOTAL_BYTES_WRITTEN', 'CHECKPOINT_LATENCY', 'WRITE_TO_WAL_LATENCY']);
SELECT cron($$CALL enable_profiling(format := 'no_output', coverage := 'all',
     metrics := ['LATENCY', 'CPU_TIME', 'BLOCKED_THREAD_TIME', 'RESULT_SET_SIZE', 'CUMULATIVE_ROWS_SCANNED', 'SYSTEM_PEAK_BUFFER_MEMORY',
                 'SYSTEM_PEAK_TEMP_DIR_SIZE', 'TOTAL_MEMORY_ALLOCATED', 'TOTAL_BYTES_READ', 'TOTAL_BYTES_WRITTEN', 'CHECKPOINT_LATENCY', 'WRITE_TO_WAL_LATENCY']);
CHECKPOINT$$, '45 */5 * * * *');

-- Queries from DuckDB's own log, and one row per profiled statement: its QueryLog row and the profiler's query-level
-- metrics (seconds and bytes). A statement logs one 'Metrics' row per metric, keyed like its QueryLog row by
-- (connection_id, query_id).
CREATE SCHEMA IF NOT EXISTS meta;
CREATE OR REPLACE VIEW meta.query_log AS SELECT * EXCLUDE (type, message), message AS query FROM duckdb_logs WHERE type = 'QueryLog';
CREATE OR REPLACE VIEW meta.query_metrics AS
WITH metric AS (
    SELECT connection_id, query_id, parse_duckdb_log_message('Metrics', message) AS m FROM duckdb_logs WHERE type = 'Metrics'
), per_query AS (
    SELECT connection_id, query_id, map_from_entries(list((m.metric, m.value))) AS v FROM metric GROUP BY ALL
)
SELECT q.timestamp, q.connection_id, q.query_id, q.query,
       v['LATENCY']::DOUBLE AS latency_s, v['CPU_TIME']::DOUBLE AS cpu_s, v['BLOCKED_THREAD_TIME']::DOUBLE AS blocked_thread_s,
       v['RESULT_SET_SIZE']::UBIGINT AS result_bytes, v['CUMULATIVE_ROWS_SCANNED']::UBIGINT AS rows_scanned,
       v['SYSTEM_PEAK_BUFFER_MEMORY']::UBIGINT AS peak_buffer_bytes, v['SYSTEM_PEAK_TEMP_DIR_SIZE']::UBIGINT AS peak_temp_bytes,
       v['TOTAL_MEMORY_ALLOCATED']::UBIGINT AS allocated_bytes, v['TOTAL_BYTES_READ']::UBIGINT AS bytes_read,
       v['TOTAL_BYTES_WRITTEN']::UBIGINT AS bytes_written, v['CHECKPOINT_LATENCY']::DOUBLE AS checkpoint_s,
       v['WRITE_TO_WAL_LATENCY']::DOUBLE AS wal_write_s, v AS metrics
FROM meta.query_log q JOIN per_query USING (connection_id, query_id);

-- Extension docs: lake.agents.ext_fetch keeps every fetch (url, fetched_at, response {status, body}); agents.ext_docs is
-- each fetch with its page as markdown (a community page carries the extension's whole function reference). Daily, the
-- community list and every extension page it links are fetched again: one curl per url, four /sql bodies run in order.
CREATE SCHEMA IF NOT EXISTS agents;
SELECT cron($$
WITH urls AS (
    SELECT 'https://duckdb.org/community_extensions/list_of_extensions' AS url
    UNION
    SELECT url_resolve(f.url, l.href) AS url FROM lake.agents.ext_fetch f
    CROSS JOIN UNNEST(html_extract_links(parse_html(f.response ->> 'body'))) AS u(l)
    WHERE f.url = 'https://duckdb.org/community_extensions/list_of_extensions'
      AND urlpattern_test('https://duckdb.org/community_extensions/extensions/:name.html', url_resolve(f.url, l.href))
), batches AS (
    SELECT list(url ORDER BY url) AS urls, now() AS fetched_at FROM urls GROUP BY hash(url) % 4
), statements AS (
    SELECT tera_render($t$
{% for url in urls %}
MERGE INTO lake.agents.ext_fetch AS target
USING (
    SELECT $url${{ url }}$url$ AS url, '{{ fetched_at }}'::TIMESTAMPTZ AS fetched_at,
           json_object('status', 200, 'body', content) AS response
    FROM read_text($cmd$curl -sSL --fail --max-time 30 '{{ url }}' |$cmd$)
) AS source ON target.url = source.url AND target.fetched_at = source.fetched_at
WHEN NOT MATCHED THEN INSERT BY NAME;
{% endfor %}
$t$, c::JSON, autoescape := false) AS sql
    FROM batches c
), posted AS (
    SELECT array_agg(quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', sql)::VARCHAR)) AS receipts FROM statements
)
SELECT r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r)
$$, '0 15 3 * * *');

-- 9494 Quack.
FROM quack_serve('quack:localhost:9494', token := getenv('QUACK_TOKEN'));

-- 9495: POST /sql {"sql": "..."}; POST /inbox any JSON, read it from quackapi_jobs; GET /profile?sql=…;
-- POST /mcp/ is the dev MCP server: tools query and execute, each a native JSON post to /sql, collected and unnested as receipts.
-- The inbox queue (quackapi_jobs) lives in dev.duckdb: jobs still queued are lost when the file is reset.
CREATE QUEUE inbox;
CREATE OR REPLACE ROUTE sql POST '/sql' AS SELECT * FROM quack_query('quack:localhost:9494', $sql, token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE ROUTE inbox POST '/inbox' STATUS 201 AS SELECT quackapi_enqueue('inbox', $body::JSON) AS id;
-- GET /profile?sql=…: the query graph that `python -m duckdb.query_graph` draws. Runs the SQL (writes included) under
-- EXPLAIN (ANALYZE, FORMAT json) through Quack, keeps the profile as ~/.duck/logs/profiles/<UTC time>.json (a COPY
-- dispatched to /sql), and answers one HTML page: headline metrics, time per operator type, and the operator tree in
-- preorder with each node's share of operator time. jsonata walks the children; the EXPLAIN_ANALYZE wrapper is skipped.
SELECT content FROM read_text('mkdir -p ~/.duck/logs/profiles |');
CREATE OR REPLACE ROUTE profile GET '/profile' AS
WITH run AS (
    SELECT explain_value::JSON AS profile, explain_value AS profile_text, '~/.duck/logs/profiles/' || strftime(now(), '%Y%m%dT%H%M%S.%fZ') || '.json' AS path
    FROM quack_query('quack:localhost:9494', 'EXPLAIN (ANALYZE, FORMAT json) ' || $sql, token := getenv('QUACK_TOKEN'))
), saved AS (
    SELECT *, quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', tera_render($copy$
COPY (SELECT $profile${{ profile_text }}$profile$) TO $path${{ path }}$path$
(FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
$copy$, c::JSON, autoescape := false))::VARCHAR).status::VARCHAR AS saved_status
    FROM run c
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
    SELECT $body::JSON -> '$.id' AS id, $body::JSON ->> '$.method' AS method,
           coalesce($body::JSON ->> '$.params.arguments.sql', $body::JSON ->> '$.params.arguments.statement') AS sql
), posted AS (
    SELECT id, method, array_agg(quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', sql)::VARCHAR)) AS receipts
    FROM msg WHERE method = 'tools/call' GROUP BY id, method
), called AS (
    SELECT id, method FROM msg WHERE method IS DISTINCT FROM 'tools/call'
    UNION ALL BY NAME
    SELECT id, method,
           coalesce(try_cast(r.body AS JSON), json_object('detail', coalesce(r.error, r.body))) AS reply,
           CASE WHEN r.status = 200 THEN coalesce(json_exists(reply, '$.detail'), false) ELSE true END AS failed
    FROM posted CROSS JOIN UNNEST(receipts) AS t(r)
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
CALL enable_logging(['QueryLog', 'HTTP', 'Quack', 'Metrics'], storage := 'file', storage_path := getenv('QUACK_NATIVE_LOG'), storage_buffer_size := 0);

-- The branch views read the inframe git checkout (the working directory), which a machine without it (CI) lacks; they
-- are posted once dev is serving, so a missing checkout fails this post and nothing else.
-- branch_diff: what each local branch changed since it left origin/staging, and whether origin has it: the files a PR
-- shows, with no gh. branch_point = shared commits that no other shared commit has as a parent (git's
-- merge base). One row per branch and changed file; filter with WHERE branch_name = ….
-- branch_definition_changes: definitions each branch_diff file added, removed or modified: sitting_duck parses both
-- ends; a declaration wrapping a same-named definition (TS `const x` around its declarator) is dropped so each name
-- counts once, and the two ends join on qualified_name (scope path with per-name index), not on name. A file's blob
-- reads are correlated LATERALs, so WHERE branch_name = … reads only that branch; the side a file lacks gets a NULL uri,
-- because a WHERE inside the LATERAL does not stop the read.
SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', $views$
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
 AND after_definitions.qualified_name = before_definitions.qualified_name
$views$)).status;

-- One Parquet per session: a Claude transcript plus its subagents, or one Codex rollout.
-- Missing roots are skipped. HostFS supplies the paths, sizes and mtimes used to find changed sessions.
-- maximum_depth 1 and disabled map inference keep top-level JSON fields compatible across files.
-- 32 MB accommodates the largest transcript line; read_json buffers use twice that per thread.
CREATE SCHEMA IF NOT EXISTS agent;
CREATE OR REPLACE VIEW agent.entries AS
SELECT path, parse_dirpath(path) AS parent, file_name(path) AS name, parse_filename(path, true) AS stem, file_extension(path) AS ext,
       file_size(path) AS bytes, file_last_modified(path) AS modified,
       CASE WHEN ext = '.parquet' THEN 'read_parquet' ELSE 'read_json' END AS reader,
       CASE WHEN reader = 'read_parquet' THEN split_part(path, '/.duck/lake/agent', 2)[:-9]
            WHEN file_name(parent) = 'subagents' THEN parse_dirpath(parent)
            ELSE parent || '/' || stem END AS session
FROM (SELECT rtrim(content, e'\n') AS path
      FROM read_lines($c$for d in ~/.claude/projects ~/.codex/sessions ~/.codex/archived_sessions ~/.duck/lake/agent; do [ -d "$d" ] && find "$d" -type f \( -name '*.jsonl*' -o -name '*.parquet' \); done; true |$c$));
-- Run the same complete refresh at boot and every five minutes. Copies finish before the view is rebound.
WITH program AS (
    SELECT $refresh$
WITH c AS (
    SELECT t.session, getenv('HOME') || '/.duck/lake/agent' || t.session || '.parquet' AS stored,
           concat(chr(39), replace(parse_dirpath(stored), chr(39), $$'"'"'$$), chr(39)) AS directory,
           string_agg(concat(chr(39), replace(t.path, chr(39), chr(39)||chr(39)), chr(39)), ', ') AS files
    FROM agent.entries t LEFT JOIN agent.entries s ON s.reader = 'read_parquet' AND s.session = t.session
    WHERE t.reader = 'read_json'
    GROUP BY t.session HAVING bool_or(t.modified > coalesce(s.modified, '-infinity'::TIMESTAMP))
), statements AS (
    SELECT tera_render($copy$
SELECT content FROM read_text($cmd$mkdir -p {{ directory }} |$cmd$);
COPY (
    SELECT * FROM read_json([{{ files }}], format := 'newline_delimited', maximum_depth := 1,
        map_inference_threshold := -1, sample_size := -1, maximum_object_size := 33554432,
        ignore_errors := true, union_by_name := true, filename := 'transcript')
) TO $path${{ stored }}$path$ (FORMAT parquet);
$copy$, c::JSON, autoescape := false) AS sql FROM c
), posted AS (
    SELECT array_agg(quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', sql)::VARCHAR)) AS receipts FROM statements
)
SELECT r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

WITH c AS (
    SELECT string_agg(concat(chr(39), replace(path, chr(39), chr(39)||chr(39)), chr(39)), ', ') AS files
    FROM agent.entries WHERE reader = 'read_parquet' AND NOT starts_with(name, 'tmp_')
), statements AS (
    SELECT tera_render($view$
CREATE OR REPLACE VIEW agent.lines AS
SELECT * FROM read_parquet([{{ files }}], union_by_name := true)
SEMI JOIN agent.entries e ON e.path = transcript;
$view$, c::JSON, autoescape := false) AS sql FROM c WHERE files IS NOT NULL
), posted AS (
    SELECT array_agg(quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', sql)::VARCHAR)) AS receipts FROM statements
)
SELECT r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r);
$refresh$ AS sql
), posted AS (
    SELECT sql, array_agg(quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', sql)::VARCHAR)) AS receipts
    FROM program GROUP BY sql
)
SELECT cron(sql, '0 */5 * * * *') AS job, r.*
FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

-- The lake sits on top of the work: attached last, in one post, so a lake failure fails this post and dev keeps serving.
-- The catalog holds its own data path. 4318 OTLP/HTTP into the lake: otlp_serve creates lake.otel.otlp_* (logs, traces,
-- metrics_sum, _gauge, _histogram, _exp_histogram) and commits buffered rows about every 5 s; otlp_stop() commits them, a
-- kill drops them. After its commits it runs CHECKPOINT lake, and it sets the lake's GLOBAL expire_older_than /
-- delete_older_than to maintenance_retention_ms (default 15 min): every lake table's snapshots older than that are
-- expired. 30 days here. agents.ext_docs is each fetch in lake.agents.ext_fetch with its page as markdown.
SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', $lake$
ATTACH IF NOT EXISTS 'ducklake:~/.duck/lake/duckstack/catalog.ducklake' AS lake (DATA_INLINING_ROW_LIMIT 0);
CREATE SCHEMA IF NOT EXISTS lake.otel;
FROM otlp_serve('otlp:127.0.0.1:4318', catalog := 'lake', schema := 'otel', disable_auth := true, maintenance_retention_ms := 2592000000);
CREATE OR REPLACE VIEW agents.ext_docs AS
SELECT urlpattern_extract('https://duckdb.org/community_extensions/extensions/:name.html', url, 'name') AS extension, url, fetched_at,
       response ->> 'status' AS status,
       duck_blocks_to_md(html_to_duck_blocks((response ->> 'body')::HTML)) AS markdown
FROM lake.agents.ext_fetch
$lake$)).status;

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
-- macOS crash reports (*.ips in DiagnosticReports): each file is a one-line JSON header and a JSON body.
-- One row per report: app, time, exception, faulting address, and the faulting thread's frames with the binary each
-- frame is in (usedImages[imageIndex]); the whole body stays in report. The globs name whole folders, as in
-- host_diagnostic_files: macOS rotates .ips away, and a glob matching nothing fails the view at boot.
CREATE OR REPLACE VIEW meta.crash_reports AS
WITH doc AS (
    SELECT filename, try(decode(content)) AS txt, position($n$
$n$ IN txt) AS nl
    FROM read_blob(['/Library/Logs/DiagnosticReports/*', '~/Library/Logs/DiagnosticReports/*'])
    WHERE ends_with(filename, '.ips') AND NOT starts_with(file_name(filename), 'JetsamEvent')
), split AS (
    SELECT filename, try(left(txt, nl - 1)::JSON) AS h, try(substr(txt, nl + 1)::JSON) AS b FROM doc
)
SELECT file_name(filename) AS file, h ->> 'app_name' AS app,
       strptime(h ->> 'timestamp', '%Y-%m-%d %H:%M:%S.%f %z') AS crashed_at,
       b ->> '$.exception.type' AS exception, b ->> '$.exception.signal' AS signal, b ->> '$.exception.subtype' AS address,
       (b ->> '$.faultingThread')::INTEGER AS faulting_thread,
       b -> 'threads' -> ((b ->> '$.faultingThread')::INTEGER) -> 'frames' AS frames, b -> 'usedImages' AS images,
       b -> '$.asi' AS app_info, b AS report, filename AS path
FROM split WHERE json_exists(b, '$.threads');
-- GET /profile?sql=…: the query graph that `python -m duckdb.query_graph` draws. Runs the SQL (writes included) under
-- EXPLAIN (ANALYZE, FORMAT json) through Quack, keeps the profile as ~/.duck/logs/profiles/<UTC time>.json (a COPY
-- dispatched to /sql), and answers one HTML page: headline metrics, time per operator type, and the operator tree in
-- preorder with each node's share of operator time. json_tree lists the operators; the EXPLAIN_ANALYZE wrapper is skipped.
SELECT content FROM read_text('mkdir -p ~/.duck/logs/profiles |');
CREATE OR REPLACE ROUTE profile GET '/profile' AS
WITH run AS (
    SELECT explain_value::JSON AS profile, explain_value AS profile_text,
           strftime(now(), '~/.duck/logs/profiles/%Y%m%dT%H%M%S.%fZ.json') AS path, quote_literal(path) AS target
    FROM quack_query('quack:localhost:9494', tera_render('EXPLAIN (ANALYZE, FORMAT json) {{ sql }}', json_object('sql', $sql), autoescape := false),
                     token := getenv('QUACK_TOKEN'))
), saved AS (
    SELECT *, selfdispatch(tera_render($copy$
COPY (SELECT $profile${{ profile_text }}$profile$) TO {{ target }} (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
$copy$, c::JSON, autoescape := false)).status::VARCHAR AS saved_status
    FROM run c
), node AS (   -- every operator in the profile, in order; depth is how many children its path has
    SELECT saved.profile, saved.path, saved.saved_status, t.id AS idx, t.value ->> 'operator_name' AS name, len(string_split(t.path, 'children')) - 3 AS depth,
           (t.value ->> 'operator_timing')::DOUBLE AS seconds, (t.value ->> 'operator_cardinality')::UBIGINT AS card,
           (t.value ->> 'operator_rows_scanned')::UBIGINT AS scanned, (t.value -> 'extra_info' ->> 'Estimated Cardinality') AS est,
           list_transform(list_filter(json_keys(t.value -> 'extra_info'), lambda k: k <> 'Estimated Cardinality'), lambda k: k || ': ' || (t.value -> 'extra_info' ->> k)) AS extra
    FROM saved CROSS JOIN LATERAL json_tree(saved.profile) t
    WHERE json_exists(t.value, '$.operator_name') AND (t.value ->> 'operator_type') <> 'EXPLAIN_ANALYZE'
), share AS (
    SELECT *, seconds / sum(seconds) OVER () AS part FROM node
), operator AS (   -- each operator as the page prints it; a part the operator lacks is ''
    SELECT *, {hot: CASE WHEN part >= 0.25 THEN ' hot' ELSE '' END, indent: depth * 18, name: name,
               seconds: seconds::DECIMAL(18, 6)::VARCHAR, pct: (part * 100)::DECIMAL(18, 1)::VARCHAR,
               card: printf('%,d', card), est: coalesce(est, '?'),
               scanned: CASE WHEN scanned IS DISTINCT FROM 0 THEN tera_render(' · scanned {{ n }}', json_object('n', printf('%,d', scanned))) ELSE '' END,
               extra: CASE WHEN len(extra) > 0 THEN tera_render('<details><summary>extra info</summary><div class="m">{{ lines | join(sep="") | safe }}</div></details>',
                   json_object('lines', list_transform(extra, e -> tera_render('{{ e }}<br>', json_object('e', e))))) ELSE '' END} AS shown
    FROM share
), phase AS (
    SELECT profile, path, saved_status, name, sum(seconds) AS seconds, sum(part) AS part, count(idx) AS nodes,
           list({idx: idx, html: tera_render($node$
<div class="op{{ hot }}" style="margin-left:{{ indent }}px;--share:{{ pct }}%"><span class="n">{{ name }}</span>
<span class="m">{{ seconds }} s · {{ pct }}% · {{ card }} rows · est {{ est }}{{ scanned | safe }}</span>
{{ extra | safe }}</div>$node$, shown::JSON)}) AS members
    FROM operator GROUP BY ALL
), shown_phase AS (
    SELECT *, {name: name, nodes: nodes, seconds: seconds::DECIMAL(18, 6)::VARCHAR, pct: (part * 100)::DECIMAL(18, 1)::VARCHAR} AS shown FROM phase
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
<h1>Query profile</h1>
<p><span class="hot-text">{{ top.name }}</span> takes {{ top.pct }}% of operator CPU time ({{ top.seconds }} s of {{ cpu }} s, summed over threads, across {{ operators }} operators);
the query ran {{ latency }} s end to end. {{ saved | safe }}</p>
<section class="grid">{{ cards | join(sep="") | safe }}</section>
<details><summary>SQL</summary><pre>{{ sql }}</pre></details>
<h2>Time by operator</h2><table><tr><th>Operator</th><th>Nodes</th><th>Seconds</th><th>Share</th></tr>
{{ phases | join(sep="") | safe }}</table>
<h2>Operator tree</h2><div class="tree">{{ nodes | join(sep="") | safe }}
</div></main></body></html>$t$, json_object(
    'sql', $sql, 'cpu', sum(seconds)::DECIMAL(18, 4)::VARCHAR, 'latency', (profile ->> 'latency')::DOUBLE::DECIMAL(18, 4)::VARCHAR,
    'saved', CASE WHEN saved_status = '200' THEN tera_render('Profile saved to <code>{{ path }}</code>.', json_object('path', path))
                  ELSE tera_render('The profile was not saved (status {{ saved }}).', json_object('saved', saved_status)) END,
    'top', arg_max(shown, seconds), 'operators', len(flatten(list(members))),
    'phases', list(tera_render('<tr><td>{{ name }}</td><td>{{ nodes }}</td><td>{{ seconds }}</td><td>{{ pct }}%</td></tr>', shown::JSON) ORDER BY seconds DESC),
    'nodes', list_transform(list_sort(flatten(list(members))), m -> m.html),
    'cards', list_transform(
        [{t: 'Latency', v: (profile ->> 'latency')::DOUBLE::DECIMAL(18, 4)::VARCHAR, unit: ' s'},
         {t: 'Operator CPU', v: sum(seconds)::DECIMAL(18, 4)::VARCHAR, unit: ' s'},
         {t: 'Rows scanned', v: printf('%,d', (profile ->> 'cumulative_rows_scanned')::BIGINT), unit: ''},
         {t: 'Read', v: format_bytes((profile ->> 'total_bytes_read')::BIGINT), unit: ''},
         {t: 'Written', v: format_bytes((profile ->> 'total_bytes_written')::BIGINT), unit: ''},
         {t: 'Peak buffer memory', v: format_bytes((profile ->> 'system_peak_buffer_memory')::BIGINT), unit: ''},
         {t: 'Peak temp dir', v: format_bytes((profile ->> 'system_peak_temp_dir_size')::BIGINT), unit: ''},
         {t: 'Memory allocated', v: format_bytes((profile ->> 'total_memory_allocated')::BIGINT), unit: ''}],
        c -> tera_render('<div class="card"><b>{{ t }}</b><span>{{ v }}{{ unit }}</span></div>', c::JSON)))) AS html
FROM shown_phase GROUP BY profile, path, saved_status;

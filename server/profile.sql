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
-- macOS crash reports (~/Library/Logs/DiagnosticReports/*.ips): each file is a one-line JSON header and a JSON body.
-- One row per report: app, time, exception, faulting address, and the faulting thread's frames with the binary each
-- frame is in (usedImages[imageIndex]); the whole body stays in report.
CREATE OR REPLACE VIEW meta.crash_reports AS
WITH doc AS (
    SELECT filename, json FROM read_json_objects('~/Library/Logs/DiagnosticReports/*.ips', format := 'unstructured',
                                                 filename := true, maximum_object_size := 67108864)
), header AS (
    SELECT filename, json AS h FROM doc WHERE NOT json_exists(json, '$.threads')
), body AS (
    SELECT filename, json AS b FROM doc WHERE json_exists(json, '$.threads')
)
SELECT file_name(filename) AS file, h ->> 'app_name' AS app,
       strptime(h ->> 'timestamp', '%Y-%m-%d %H:%M:%S.%f %z') AS crashed_at,
       b ->> '$.exception.type' AS exception, b ->> '$.exception.signal' AS signal, b ->> '$.exception.subtype' AS address,
       (b ->> '$.faultingThread')::INTEGER AS faulting_thread,
       from_json(jsonata($j$(
           $imgs := usedImages;
           $ft := faultingThread;
           threads[$ft].frames.($f := $; {"image": $imgs[$f.imageIndex].($exists(name) ? name : path),
                                          "symbol": $f.symbol, "offset": $f.imageOffset})
       )$j$, b), '[{"image": "VARCHAR", "symbol": "VARCHAR", "offset": "UBIGINT"}]') AS frames,
       b -> '$.asi' AS app_info, b AS report, filename AS path
FROM header JOIN body USING (filename);
-- GET /profile?sql=…: the query graph that `python -m duckdb.query_graph` draws. Runs the SQL (writes included) under
-- EXPLAIN (ANALYZE, FORMAT json) through Quack, keeps the profile as ~/.duck/logs/profiles/<UTC time>.json (a COPY
-- dispatched to /sql), and answers one HTML page: headline metrics, time per operator type, and the operator tree in
-- preorder with each node's share of operator time. jsonata walks the children; the EXPLAIN_ANALYZE wrapper is skipped.
SELECT content FROM read_text('mkdir -p ~/.duck/logs/profiles |');
CREATE OR REPLACE ROUTE profile GET '/profile' AS
WITH run AS (
    SELECT explain_value::JSON AS profile, '~/.duck/logs/profiles/' || strftime(now(), '%Y%m%dT%H%M%S.%fZ') || '.json' AS path
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

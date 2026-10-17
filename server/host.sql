-- The Mac's apps as relations. Selecting a view reads the app live; nothing is stored.
-- One JXA call per read returns column arrays; SQL unnests them into rows. Actions are verb rows
-- rendered into osascript and sent through visible self-dispatch (SQL-MANIFESTO.md).
-- CREATE VIEW runs each command once to bind, so every read is boot-safe: it never launches an app
-- (running() first) and never fails (try → empty arrays). A closed app is a view with no rows.

-- Terminal.app ---------------------------------------------------------------------------------

CREATE OR REPLACE VIEW terminal_tabs AS
WITH terminal_read AS (   -- one osascript call: every window, every tab, column arrays
    SELECT * FROM read_json($cmd$osascript -l JavaScript -e 'var A = Application("Terminal"), W = A.windows; function g(f) { try { return A.running() ? f() : []; } catch (e) { return []; } } JSON.stringify({window_id: g(() => W.id()), window_index: g(() => W.index()), frontmost: g(() => W.frontmost()), miniaturized: g(() => W.miniaturized()), custom_title: g(() => W.tabs.customTitle()), tty: g(() => W.tabs.tty()), busy: g(() => W.tabs.busy()), processes: g(() => W.tabs.processes()), selected: g(() => W.tabs.selected()), rows: g(() => W.tabs.numberOfRows()), columns: g(() => W.tabs.numberOfColumns())})' |$cmd$)
), per_window AS (
    SELECT unnest(window_id)::BIGINT AS window_id, unnest(window_index)::INT AS window_index,
           unnest(frontmost)::BOOLEAN AS frontmost, unnest(miniaturized)::BOOLEAN AS miniaturized,
           unnest(custom_title)::VARCHAR[] AS titles, unnest(tty)::VARCHAR[] AS ttys, unnest(busy)::BOOLEAN[] AS busys,
           unnest(processes)::VARCHAR[][] AS process_lists, unnest(selected)::BOOLEAN[] AS selecteds,
           unnest(rows)::INT[] AS row_counts, unnest(columns)::INT[] AS column_counts
    FROM terminal_read
)
SELECT window_id, window_index, frontmost, miniaturized,
       unnest(generate_series(1, len(titles))) AS tab_index,
       unnest(titles) AS custom_title, unnest(ttys) AS tty, unnest(busys) AS busy,
       unnest(process_lists) AS processes, unnest(selecteds) AS selected,
       unnest(row_counts) AS rows, unnest(column_counts) AS columns
FROM per_window;

-- What each tab shows now, one row per screen line. Heavier than terminal_tabs: filter by window_id.
CREATE OR REPLACE VIEW terminal_screen_lines AS
WITH terminal_read AS (
    SELECT * FROM read_json($cmd$osascript -l JavaScript -e 'var A = Application("Terminal"), W = A.windows; function g(f) { try { return A.running() ? f() : []; } catch (e) { return []; } } JSON.stringify({window_id: g(() => W.id()), contents: g(() => W.tabs.contents())})' |$cmd$,
                            maximum_object_size := 67108864)
), per_window AS (
    SELECT unnest(window_id)::BIGINT AS window_id, unnest(contents)::VARCHAR[] AS screens FROM terminal_read
), per_tab AS (
    SELECT window_id, unnest(generate_series(1, len(screens))) AS tab_index, unnest(screens) AS screen FROM per_window
)
SELECT window_id, tab_index, line_number, line
FROM per_tab CROSS JOIN UNNEST(string_split(screen, $n$
$n$)) WITH ORDINALITY AS l(line, line_number);

-- One row per live claude process, written by Claude Code itself (~/.claude/sessions/<pid>.json), with every key the
-- files hold as a column. Nothing names a key, so a key Claude Code stops writing is simply absent.
CREATE OR REPLACE VIEW claude_sessions AS
SELECT * FROM read_json('/Users/aloksubbarao/.claude/sessions/*.json', union_by_name := true, ignore_errors := true);

-- Each Terminal tab, the claude process holding its tty, and that session. pgrep -t ignores the tty
-- on macOS; lsof -t <tty> lists exactly the processes on it, one pid per line.
CREATE OR REPLACE VIEW terminal_sessions AS
WITH intent AS (          -- for each Terminal tab: every process holding its tty open
    SELECT window_id, tab_index, ['lsof', '-t', tty] AS cmd FROM terminal_tabs
), rendered AS (
    SELECT tera_render($t$SELECT {{ window_id }} AS window_id, {{ tab_index }} AS tab_index, pid FROM read_csv($cmd${{ cmd | join(sep=" ") }} |$cmd$, header := false, names := ['pid'])$t$,
                       intent::JSON, autoescape := false) AS sql
    FROM intent
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
), tty_pids AS (
    SELECT (row ->> 'window_id')::BIGINT AS window_id, (row ->> 'tab_index')::INT AS tab_index, (row ->> 'pid')::BIGINT AS pid
    FROM dispatched CROSS JOIN UNNEST(receipts) AS t(r) CROSS JOIN UNNEST(coalesce(try_cast(r.body AS JSON[]), [])) AS u(row)
)
SELECT t.*, c.*
FROM terminal_tabs AS t
LEFT JOIN (tty_pids JOIN claude_sessions AS c USING (pid)) USING (window_id, tab_index);

-- Grammar: a new Terminal action is a new row. `do script` types into the tab; long text arrives in
-- claude as a paste and does not submit, so `submit` (a bare carriage return) goes in a SEPARATE send,
-- after the paste has landed. Send only to sessions whose terminal_sessions.status is idle or busy:
-- text typed at a permission prompt or a question answers it.
CREATE OR REPLACE VIEW terminal_verbs AS
SELECT 'type' AS verb, ['do script'] AS words, true AS takes_text, true AS targets_tab UNION ALL
SELECT 'wait', ['delay 0.5'], false, false UNION ALL
SELECT 'submit', ['do script (ASCII character 13)'], false, true;

-- Google Chrome --------------------------------------------------------------------------------

-- Chrome's scripting doesn't expose the profile. A window is 'work' when any tab is on a work host.
CREATE OR REPLACE VIEW chrome_profile_markers AS
SELECT 'work' AS profile, 'app.rippling.com' AS host, '' AS path_prefix UNION ALL
SELECT 'work', 'linear.app', '/inframe-risk' UNION ALL
SELECT 'work', 'inframerisk.com', '' UNION ALL
SELECT 'work', 'inframerisk.net', '';

CREATE OR REPLACE VIEW chrome_all_tabs AS
WITH chrome_read AS (     -- one osascript call: every window, every tab, column arrays
    SELECT * FROM read_json($cmd$osascript -l JavaScript -e 'var A = Application("Google Chrome"), W = A.windows; function g(f) { try { return A.running() ? f() : []; } catch (e) { return []; } } JSON.stringify({window_id: g(() => W.id()), window_index: g(() => W.index()), given_name: g(() => W.givenName()), active_tab_index: g(() => W.activeTabIndex()), mode: g(() => W.mode()), tab_id: g(() => W.tabs.id()), url: g(() => W.tabs.url()), title: g(() => W.tabs.title()), loading: g(() => W.tabs.loading())})' |$cmd$)
), per_window AS (
    SELECT unnest(window_id)::BIGINT AS window_id, unnest(window_index)::INT AS window_index, unnest(given_name)::VARCHAR AS given_name,
           unnest(active_tab_index)::INT AS active_tab_index, unnest(mode)::VARCHAR AS mode,
           unnest(tab_id)::BIGINT[] AS tab_ids, unnest(url)::VARCHAR[] AS urls, unnest(title)::VARCHAR[] AS titles,
           unnest(loading)::BOOLEAN[] AS loadings
    FROM chrome_read
), per_tab AS (
    SELECT window_id, window_index, given_name, active_tab_index, mode, len(tab_ids) AS tab_count,
           unnest(generate_series(1, len(tab_ids))) AS tab_index, unnest(tab_ids) AS tab_id,
           unnest(urls) AS url, unnest(titles) AS title, unnest(loadings) AS loading
    FROM per_window
), window_profile AS (
    SELECT t.window_id, list_distinct(list(m.profile)) AS matched_profiles
    FROM per_tab AS t
    LEFT JOIN chrome_profile_markers AS m
      ON ends_with('.' || extract_host(t.url), '.' || m.host) AND starts_with(extract_path(t.url), m.path_prefix)
    GROUP BY t.window_id
)
SELECT t.*, t.tab_index = t.active_tab_index AS active,
       coalesce(p.matched_profiles[1], CASE t.mode WHEN 'incognito' THEN 'incognito' ELSE 'personal' END) AS profile
FROM per_tab AS t JOIN window_profile AS p USING (window_id);

CREATE OR REPLACE VIEW chrome_windows AS
SELECT window_id, window_index, given_name, mode, profile, active_tab_index, tab_count
FROM chrome_all_tabs GROUP BY ALL;

-- Work tabs by default; narrow to one window with WHERE window_id = …
CREATE OR REPLACE VIEW chrome_tabs AS
SELECT window_id, tab_index, tab_id, url, title, loading, active, profile
FROM chrome_all_tabs WHERE profile = 'work';

-- Grammar: a new Chrome action is a new row. The target clause (window id / tab id) comes from SQL.
CREATE OR REPLACE VIEW chrome_verbs AS
SELECT 'open_url' AS verb, ['make new tab at end of tabs of'] AS words, 'window' AS target, ['with properties {URL:'] AS preposition, ['}'] AS closing, 'text' AS argument_type UNION ALL
SELECT 'set_active_tab_url', ['set URL of active tab of'], 'window', ['to'], [], 'text' UNION ALL
SELECT 'execute_javascript', ['execute'], 'tab', ['javascript'], [], 'text' UNION ALL
SELECT 'close_tab', ['close'], 'tab', [], [], 'none' UNION ALL
SELECT 'activate_tab', ['set active tab index of'], 'window', ['to'], [], 'integer';

-- Processes and macOS diagnostics -------------------------------------------------------------------

-- Every process now. footprint_mb is top's MEM, what Activity Monitor shows: it counts compressed and swapped pages,
-- which ps's RSS does not. spawned_by names the agent behind a process group: 'claude' (the group leader is the zsh
-- a Claude Bash call starts, sourcing ~/.claude/shell-snapshots), 'codex' (a child of codex outside its own install
-- and MCP servers), 'orphan' (the leader is gone: an agent's call ended and left its job running). ps and date print
-- local wall time, so age_s compares like with like.
CREATE OR REPLACE VIEW host_processes AS
WITH ps AS (
    FROM read_csv($cmd$ps -axww -o pid=,ppid=,pgid=,rss=,lstart=,args= | awk -v now="$(date '+%Y-%m-%d %H:%M:%S')" '{a=$0; sub(/^ *[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ +[A-Z][a-z][a-z] +[A-Z][a-z][a-z] +[0-9]+ +[0-9:]+ +[0-9]+ +/, "", a); print now"\t"$1"\t"$2"\t"$3"\t"$4"\t"$5" "$6" "$7" "$8" "$9"\t"substr(a,1,2000)}' |$cmd$,
                  delim := '\t', header := false, quote := '', escape := '',
                  columns := {'observed_at': 'TIMESTAMP', 'pid': 'BIGINT', 'ppid': 'BIGINT', 'pgid': 'BIGINT', 'rss_kb': 'BIGINT',
                              'lstart': 'VARCHAR', 'args': 'VARCHAR'})
), top AS (
    FROM read_csv($cmd$top -l 1 -stats pid,mem,cmprs | awk 'NR>12 {print $1"\t"$2"\t"$3}' |$cmd$, delim := '\t', header := false,
                  columns := {'pid': 'BIGINT', 'mem': 'VARCHAR', 'cmprs': 'VARCHAR'})
), procs AS (
    SELECT ps.* EXCLUDE (lstart), strptime(lstart, '%a %b %d %H:%M:%S %Y') AS started_at,
           date_diff('second', started_at, observed_at) AS age_s,
           CASE right(rtrim(mem, '+-'), 1) WHEN 'G' THEN 1024 WHEN 'M' THEN 1 WHEN 'K' THEN 1/1024 ELSE 0 END
             * TRY_CAST(rtrim(rtrim(mem, '+-'), 'BKMG') AS DOUBLE) AS footprint_mb,
           CASE right(rtrim(cmprs, '+-'), 1) WHEN 'G' THEN 1024 WHEN 'M' THEN 1 WHEN 'K' THEN 1/1024 ELSE 0 END
             * TRY_CAST(rtrim(rtrim(cmprs, '+-'), 'BKMG') AS DOUBLE) AS compressed_mb
    FROM ps LEFT JOIN top USING (pid)
)
SELECT g.*, l.args AS leader_args, p.args AS parent_args,
       CASE WHEN g.pgid <= 1 THEN NULL
            WHEN l.pid IS NULL THEN 'orphan'
            WHEN contains(l.args, '/.claude/shell-snapshots/') THEN 'claude'
            WHEN p.args SIMILAR TO '.*/codex( .*)?' AND NOT starts_with(g.args, '/Applications/ChatGPT.app/')
                 AND NOT starts_with(g.args, '/Users/aloksubbarao/.codex/')
                 AND NOT starts_with(g.args, '/Users/aloksubbarao/.local/bin/') THEN 'codex'
       END AS spawned_by
FROM procs g LEFT JOIN procs l ON l.pid = g.pgid LEFT JOIN procs p ON p.pid = g.ppid;

-- Every file macOS keeps in DiagnosticReports: crash reports (.ips), out-of-memory kills (JetsamEvent*.ips), resource
-- reports (.diag: disk writes, CPU, wakeups). The globs name whole folders, which always hold files: a glob matching
-- nothing fails the view. read_blob because some .ips are gzip archives, not text.
CREATE OR REPLACE VIEW host_diagnostic_files AS
SELECT filename AS path, file_name(filename) AS file, last_modified, content
FROM read_blob(['/Library/Logs/DiagnosticReports/*', '~/Library/Logs/DiagnosticReports/*']);

-- One row per process in each out-of-memory kill: what was resident when macOS ran out and started killing.
CREATE OR REPLACE VIEW host_jetsam AS
WITH doc AS (
    SELECT file, decode(content) AS txt, substr(txt, position($n$
$n$ IN txt) + 1)::JSON AS b
    FROM host_diagnostic_files WHERE file LIKE 'JetsamEvent%.ips'
)
SELECT file, strptime(b ->> 'date', '%Y-%m-%d %H:%M:%S.%f %z') AS jetsam_at, b ->> 'largestProcess' AS largest_process,
       p ->> 'name' AS name, (p ->> 'pid')::BIGINT AS pid,
       ((p ->> 'rpages')::BIGINT * (b ->> '$.memoryStatus.pageSize')::BIGINT) >> 20 AS resident_mb,
       p ->> 'reason' AS reason, p ->> 'coalition' AS coalition, p AS process
FROM doc CROSS JOIN UNNEST((b -> 'processes')::JSON[]) AS t(p);

-- One row per resource report: the process, the app that owns it (coalition), and what it exceeded.
CREATE OR REPLACE VIEW host_resource_reports AS
WITH kv AS (
    SELECT file, trim(split_part(line, ':', 1)) AS k, arg_min(trim(substr(line, position(':' IN line) + 1)), n) AS v
    FROM host_diagnostic_files
    CROSS JOIN UNNEST(string_split(decode(content), $n$
$n$)[1:45]) WITH ORDINALITY AS t(line, n)
    WHERE file LIKE '%.diag' AND position(':' IN line) > 1 AND NOT starts_with(line, ' ')
    GROUP BY ALL
), h AS (
    SELECT file, map_from_entries(list((k, v))) AS h FROM kv GROUP BY file
)
SELECT file, strptime(h['Date/Time'], '%Y-%m-%d %H:%M:%S.%f %z') AS reported_at, h['Command'] AS command,
       h['PID']::BIGINT AS pid, split_part(trim(h['Resource Coalition'], '"'), '"', 1) AS coalition, h['Event'] AS event,
       h['Action taken'] AS action, coalesce(h['Writes'], h['CPU'], h['Wakeups'], h['Footprint'], h['Memory']) AS detail, h AS header
FROM h;

-- The whole Mac's memory now, one row: free, compressor, wired, swap, and the kernel's own pressure reading
-- (kern.memorystatus_level is the percent of memory it counts as available; vm.memory_pressure 0 normal, 1 warn, 2 critical).
-- observed_at is local wall time, like host_processes.
CREATE OR REPLACE VIEW host_memory AS
WITH kv AS (
    SELECT trim(split_part(content, ':', 1), ' "') AS k, rtrim(trim(substr(content, position(':' IN content) + 1)), '.') AS v
    FROM read_lines($cmd$echo "observed_at: $(date '+%Y-%m-%d %H:%M:%S')"; sysctl hw.memsize hw.pagesize kern.memorystatus_level vm.memory_pressure; sysctl -n vm.swapusage | awk '{print "swap_total: "$3; print "swap_used: "$6}'; vm_stat |$cmd$, "trim" := true)
    WHERE position(':' IN content) > 0
), h AS (
    SELECT map_from_entries(list((k, v))) AS h FROM kv
)
SELECT h['observed_at']::TIMESTAMP AS observed_at,
       h['hw.memsize']::UBIGINT >> 20 AS ram_mb,
       h['kern.memorystatus_level']::INT AS memorystatus_free_pct,
       h['vm.memory_pressure']::INT AS memory_pressure,
       h['hw.pagesize']::BIGINT AS page_bytes,
       (h['Pages free']::BIGINT * page_bytes) >> 20 AS free_mb,
       (h['Pages occupied by compressor']::BIGINT * page_bytes) >> 20 AS compressor_mb,
       (h['Pages stored in compressor']::BIGINT * page_bytes) >> 20 AS compressed_data_mb,
       (h['Pages wired down']::BIGINT * page_bytes) >> 20 AS wired_mb,
       rtrim(h['swap_total'], 'M')::DOUBLE AS swap_total_mb, rtrim(h['swap_used'], 'M')::DOUBLE AS swap_used_mb,
       h['Swapins']::BIGINT AS swapins, h['Swapouts']::BIGINT AS swapouts, h AS counters
FROM h;

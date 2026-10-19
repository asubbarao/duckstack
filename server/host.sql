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
SELECT * FROM read_json($cmd$cat "$HOME"/.claude/sessions/*.json 2>/dev/null; true |$cmd$, ignore_errors := true);

-- Each Terminal tab, the claude process holding its tty, and that session. pgrep -t ignores the tty
-- on macOS; lsof -t <tty> lists exactly the processes on it, one pid per line.
CREATE OR REPLACE VIEW terminal_sessions AS
WITH intent AS (          -- for each Terminal tab: every process holding its tty open
    SELECT window_id, tab_index, ['lsof', '-t', tty] AS cmd FROM terminal_tabs
), rendered AS (
    SELECT window_id, tab_index,
           tera_render($t$SELECT * FROM read_csv($cmd${{ cmd | join(sep=" ") }} |$cmd$, header := false, names := ['pid'])$t$,
                       intent::JSON, autoescape := false) AS sql
    FROM intent
), dispatched AS (       -- each receipt kept beside the tab it answers for
    SELECT array_agg({window_id: window_id, tab_index: tab_index, receipt: selfdispatch(sql)}) AS receipts FROM rendered
), tty_pids AS (
    SELECT r.window_id, r.tab_index, unnest(json_extract_string(try_cast(r.receipt.body AS JSON), '$[*].pid'))::BIGINT AS pid
    FROM dispatched CROSS JOIN UNNEST(receipts) AS t(r)
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

-- Safari's windows and tabs, one JXA call (empty when Safari is not running; nothing launches it).
CREATE OR REPLACE VIEW safari_tabs AS
WITH safari_read AS (
    SELECT * FROM read_json($cmd$osascript -l JavaScript -e 'var A = Application("Safari"); function g(f) { try { return A.running() ? f() : []; } catch (e) { return []; } } JSON.stringify({window_id: g(() => A.windows.id()), url: g(() => A.windows.tabs.url())})' |$cmd$)
), per_window AS (
    SELECT unnest(window_id)::BIGINT AS window_id, unnest(url)::VARCHAR[] AS urls FROM safari_read
)
SELECT window_id, unnest(generate_series(1, len(urls))) AS tab_index, unnest(urls) AS url FROM per_window;

-- Every browser tab: Chrome (any profile, incognito included) and Safari.
CREATE OR REPLACE VIEW browser_tabs AS
SELECT 'Google Chrome' AS application, profile, window_id, tab_id, tab_index, url FROM chrome_all_tabs
UNION ALL BY NAME
SELECT 'Safari' AS application, 'safari' AS profile, window_id, tab_index, url FROM safari_tabs;

-- Where an action can happen. A new target is a new row.
CREATE OR REPLACE VIEW browser_surfaces AS
SELECT 'staging-lens' AS surface, 'Google Chrome' AS application, 'work' AS profile, 'https://broker.staging.inframerisk.net/' AS url_prefix UNION ALL
SELECT 'demo-lens', 'Google Chrome', 'work', 'https://broker.demo.inframerisk.net/' UNION ALL
SELECT 'prod-lens', 'Google Chrome', 'work', 'https://broker.app.inframerisk.com/' UNION ALL
SELECT 'aws-signin', 'Google Chrome', 'work', 'https://us-west-2.signin.aws.amazon.com/' UNION ALL
SELECT 'aws-callback', 'Google Chrome', 'work', 'http://127.0.0.1:' UNION ALL
SELECT 'rippling', 'Google Chrome', 'work', 'https://app.rippling.com/' UNION ALL
-- Rippling's course player. Its SCORM content is a cross-origin frame that eval cannot reach, and opened alone it never starts.
SELECT 'go1-player', 'Google Chrome', 'work', 'https://69cd86e0bd11ec4a8e4514ca.mygo1.com/' UNION ALL
SELECT 'incognito-local-broker', 'Google Chrome', 'incognito', 'http://localhost:' UNION ALL
SELECT 'safari-local-portal', 'Safari', 'safari', 'http://local-portal:';

-- The tabs open on each surface right now.
CREATE OR REPLACE VIEW browser_targets AS
SELECT s.surface, t.* FROM browser_surfaces AS s
JOIN browser_tabs AS t ON t.application = s.application AND t.profile = s.profile AND starts_with(t.url, s.url_prefix);

-- What can be done in a browser, as AppleScript with Tera holes ({{ window_id }}, {{ tab_id }}, {{ tab_index }},
-- {{ url }}, {{ js }}). scope 'tab' runs on a browser_targets row, 'window' on a window of the surface's profile.
-- Everything stays in the background: no verb activates the app, and open puts the window's active tab back.
CREATE OR REPLACE VIEW browser_verbs AS
SELECT 'Google Chrome' AS application, 'open' AS verb, 'window' AS scope, $osa$tell application "Google Chrome"
  set w to window id {{ window_id }}
  set k to active tab index of w
  set t to make new tab at end of tabs of w with properties {URL:"{{ url }}"}
  set active tab index of w to k
  return id of t
end tell$osa$ AS osascript UNION ALL
SELECT 'Google Chrome', 'wait', 'tab', $osa$tell application "Google Chrome"
  set t to tab id {{ tab_id }} of window id {{ window_id }}
  repeat 60 times
    if not (loading of t) then exit repeat
    delay 0.25
  end repeat
  return URL of t
end tell$osa$ UNION ALL
SELECT 'Google Chrome', 'eval', 'tab', $osa$tell application "Google Chrome"
  set t to tab id {{ tab_id }} of window id {{ window_id }}
  repeat 60 times
    if not (loading of t) then exit repeat
    delay 0.25
  end repeat
  execute t javascript "{{ js }}"
end tell$osa$ UNION ALL
SELECT 'Google Chrome', 'go', 'tab', $osa$tell application "Google Chrome"
  set t to tab id {{ tab_id }} of window id {{ window_id }}
  set URL of t to "{{ url }}"
  repeat 60 times
    if not (loading of t) then exit repeat
    delay 0.25
  end repeat
  return URL of t
end tell$osa$ UNION ALL
-- show makes the tab its window's active tab (Chrome stays behind other apps), so pages that render only when visible draw.
SELECT 'Google Chrome', 'show', 'tab', $osa$tell application "Google Chrome" to set active tab index of window id {{ window_id }} to {{ tab_index }}$osa$ UNION ALL
SELECT 'Google Chrome', 'close', 'tab', $osa$tell application "Google Chrome" to close tab id {{ tab_id }} of window id {{ window_id }}$osa$ UNION ALL
SELECT 'Safari', 'eval', 'tab', $osa$tell application "Safari" to do JavaScript "{{ js }}" in tab {{ tab_index }} of window id {{ window_id }}$osa$ UNION ALL
SELECT 'Safari', 'go', 'tab', $osa$tell application "Safari" to set URL of tab {{ tab_index }} of window id {{ window_id }} to "{{ url }}"$osa$ UNION ALL
SELECT 'Safari', 'close', 'tab', $osa$tell application "Safari" to close tab {{ tab_index }} of window id {{ window_id }}$osa$;

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

-- The unified log's out-of-memory lines from the last 30 minutes (~3 s to read; a 24 h window takes ~110 s). On this
-- macOS the kernel persists no "memorystatus" lines, even with --info, around a real kill; "jetsam" catches the kill
-- itself (ReportSystemMemory: "Process X [pid] killed by jetsam reason …") and runningboard's priority updates.
-- read_lines, not read_json: an empty window is only log's {"count":0} trailer, which a schema could not bind to.
CREATE OR REPLACE VIEW host_kernel_memory_log AS
WITH l AS (
    SELECT content::JSON AS e
    FROM read_lines($cmd$log show --last 30m --style ndjson --predicate 'eventMessage CONTAINS[c] "jetsam" AND process != "log"' |$cmd$)
)
SELECT strptime(e ->> 'timestamp', '%Y-%m-%d %H:%M:%S.%f%z') AS logged_at, file_name(e ->> 'processImagePath') AS process,
       (e ->> 'processID')::BIGINT AS pid, e ->> 'messageType' AS message_type, e ->> 'subsystem' AS subsystem,
       e ->> 'category' AS category, e ->> 'eventMessage' AS message, e AS event
FROM l WHERE e ->> 'eventMessage' IS NOT NULL;

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
-- observed_at is now(), like host_processes.
CREATE OR REPLACE VIEW host_memory AS
WITH kv AS (
    SELECT trim(split_part(content, ':', 1), ' "') AS k, rtrim(trim(substr(content, position(':' IN content) + 1)), '.') AS v
    FROM read_lines($cmd$sysctl hw.memsize hw.pagesize kern.memorystatus_level vm.memory_pressure vm.swapusage; vm_stat |$cmd$, "trim" := true)
    WHERE position(':' IN content) > 0
), h AS (   -- vm.swapusage reads "total = 5120.00M  used = 3542.56M  free = …"
    SELECT map_from_entries(list((k, v))) AS h, list_filter(string_split(h['vm.swapusage'], ' '), w -> w <> '') AS swap FROM kv
)
SELECT now() AS observed_at,
       h['hw.memsize']::UBIGINT >> 20 AS ram_mb,
       h['kern.memorystatus_level']::INT AS memorystatus_free_pct,
       h['vm.memory_pressure']::INT AS memory_pressure,
       h['hw.pagesize']::BIGINT AS page_bytes,
       (h['Pages free']::BIGINT * page_bytes) >> 20 AS free_mb,
       (h['Pages occupied by compressor']::BIGINT * page_bytes) >> 20 AS compressor_mb,
       (h['Pages stored in compressor']::BIGINT * page_bytes) >> 20 AS compressed_data_mb,
       (h['Pages wired down']::BIGINT * page_bytes) >> 20 AS wired_mb,
       rtrim(swap[3], 'M')::DOUBLE AS swap_total_mb, rtrim(swap[6], 'M')::DOUBLE AS swap_used_mb,
       h['Swapins']::BIGINT AS swapins, h['Swapouts']::BIGINT AS swapouts, h AS counters
FROM h;

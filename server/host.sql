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

# One setup.sql, every agent its own DuckDB

Status doc for the design. Checked against the running dev server on 2026-09-28
(POST `http://127.0.0.1:9495/sql`, DuckDB v1.5.5, `whoami()` = `dev`).

## Principles

1. **DuckDB is a stateless endpoint with extensions.** The knowledge is a short SQL file, not a
   database file. `~/.duck/dev.duckdb` is a disposable cache of immutable files, crawls and logs.
2. **A break means setup.sql is not right yet.** If the server lacks something (an extension not
   loaded, a tool missing, a view gone), the fix is to put it in `setup.sql` and throw the server
   away. The `light-switch` skill kills and relaunches `com.inframe.quack`; saving any file under
   `~/duckdb-skills/server/` restarts it through the `com.inframe.quack-reload` launchd watcher.
   Never `INSTALL`/`LOAD`/`PRAGMA mcp_publish_tool` against the live server as a repair.
3. **Objects are unmaterialized views; derived things are tables.** Files by glob, git through
   `duck_tails`, shellfs/hostfs output, transcripts through `agent_data`, Chrome tabs through
   osascript: all views over `ls()`, `read_*`, `git_*`, `read_conversations`. Anything computed
   from them (an extension catalog, a BM25 index, a crawl cache) is a table kept by a cron.
4. **The quack server is not special.** Any agent can start its own DuckDB from the same file on a
   free port. Ten agents, ten ports. The MCP can point at any of them.
5. **Telemetry converges.** Every agent's DuckDB reports to the central system server
   (9494 quack / 9495 quackapi) through `quack_query`, never `ATTACH`.

## Target shape of setup.sql (a sketch, about 40 lines)

```sql
-- 1. universe of extensions: idempotent, no download once present
INSTALL quack FROM community; LOAD quack;      INSTALL quackapi FROM community; LOAD quackapi;
INSTALL shellfs FROM community; LOAD shellfs;  INSTALL hostfs FROM community; LOAD hostfs;
INSTALL http_client FROM community; LOAD http_client;  INSTALL webbed FROM community; LOAD webbed;
INSTALL agent_data FROM community; LOAD agent_data;    INSTALL cronjob FROM community; LOAD cronjob;
INSTALL duck_tails FROM community; LOAD duck_tails;    INSTALL tera FROM community; LOAD tera;
-- ... crawler, markdown, scalarfs, parser_tools, quickjs, pdf, yaml, gh, duck_hunt, zipfs

-- 2. objects as unmaterialized views
CREATE OR REPLACE VIEW hostfs_ls AS SELECT file_name(path) AS file_name, is_dir(path) AS is_dir,
    file_size(path) AS file_size, file_last_modified(path) AS file_last_modified, /* every hostfs scalar */ * FROM ls();
CREATE OR REPLACE VIEW host_listeners AS FROM read_lines('lsof -nP -iTCP -sTCP:LISTEN |');
CREATE OR REPLACE VIEW chrome_tabs AS FROM read_csv('osascript -e ''...'' |');            -- duckdb-chrome-bridge
CREATE OR REPLACE VIEW conversations AS FROM read_conversations(path := '~/.claude', source := 'claude');
CREATE OR REPLACE VIEW ext_docs AS SELECT extension_name, duck_blocks_to_md(html_to_duck_blocks(...)) FROM ext_page;

-- 3. derived things as tables, refreshed by cron (or a cron.sql this file .reads)
SELECT cron($$INSERT OR REPLACE INTO ext_page BY NAME ...$$, '10 * * * * *');
SELECT cron($$INSERT INTO agent.stream BY NAME ...$$, '0 */5 * * * *');

-- 4. serve: one route that runs anything, looping back through quack
FROM quack_serve('quack:localhost:' || getenv('PORT'), token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE ROUTE sql POST '/sql' AS SELECT * FROM quack_query('quack:localhost:...', $sql, token := getenv('QUACK_TOKEN'));
FROM quackapi_serve(getenv('API_PORT')::INTEGER, host := '127.0.0.1');
```

A self-dispatch macro may come later as a convenience; agents must understand the mechanics
first (the hand-written ls crawl in `skills/self-dispatch/references/declarative_ls.sql`).

## Per-agent server flow

1. Get `setup.sql` from git: `git_read` through `duck_tails` on the dev MCP, or a clone.
2. Find ports in use through shellfs, as rows, and pick a free one in SQL:
   ```sql
   WITH used AS (SELECT try_cast(regexp_extract(content, ':(\d+) \(LISTEN\)', 1) AS INTEGER) AS port
                 FROM read_lines('lsof -nP -iTCP -sTCP:LISTEN |'))
   SELECT p AS port FROM range(9498, 9600) r(p) ANTI JOIN used ON used.port = r.p ORDER BY p LIMIT 1;
   ```
   (`LIMIT 1` is allowed here only as the port choice; the `used` relation stays whole.)
3. Start `duckdb :memory: -init setup.sql` with `DEV_QUACK_PORT`/`DEV_QUACKAPI_PORT`/`DEV_MCP_PORT`
   set to the chosen ports. `.read`/`-init` is acceptable for the initial setup; everything after
   is self-dispatch. Ten agents produce 9498, 9499, 9501, ... The MCP is added with
   `claude mcp add --transport http <name> http://localhost:<mcp port>/mcp`.
4. Install whatever a task needs on that instance (`findtype`, `fakeit`, `anofox statistics`):
   `INSTALL x FROM community; LOAD x;` is one line, never a blocker.

## Telemetry

Every agent's DuckDB keeps DuckDB's native logs (`enable_logging` types QueryLog, HTTP, Quack,
Metrics) and posts what matters to the system server: `quack_query('quack:localhost:9494',
$$INSERT INTO agents.telemetry BY NAME ...$$, token := getenv('QUACK_TOKEN'))`. OTLP from any
process lands on dev's `/v1/logs`, `/v1/traces`, `/v1/metrics` routes as raw files, read back by
the `otlp_events` view. The `query-duckdb` skill is the agent-facing half: the agent writes SQL,
the skill sends it by `quack_query` to the system server. Not `ATTACH`.

## Self-dispatch forms

| form | mechanism | on dev |
|---|---|---|
| http_client | `http_post('http://127.0.0.1:9495/sql', MAP{...}, json_object('sql', stmt))` per row, `array_agg`, `CROSS JOIN UNNEST` | works (`declarative_ls.sql`, verified) |
| shellfs curl | `read_lines('curl -s -X POST localhost:9495/sql ... \|')` | works, same route |
| HTTP server extension | quackapi in-process; a `ROUTE` is stored SQL run on another connection | `/sql`, `/query`, `/v1/*` |
| quackapi routes | `CREATE OR REPLACE ROUTE ... AS SELECT * FROM quack_query(...)` | the `/sql` route itself is this form |
| quack | `quack_query('quack:localhost:9494', $$...$$, token := ...)` from any DuckDB | works; agents most often get the token or the one-body rule wrong |

Quality bar for the SQL in every form: fewer lines by shape (keywords and commas; a long CASE is
one expression; `count(*) FILTER` four times is four). Never pre-aggregate or drop information in a
base layer; keep raw rows and add columns. `array_agg` + `len` instead of `count`; no `COUNT(*)`,
no `min`/`max`/`avg` in base layers, no `OR` chains of `LIKE`/`contains`.

## Where reality is today

`~/duckdb-skills/server/setup.sql` is 397 lines and `.read`s nine more files (699 lines:
`duckdb_mcp.sql` 182, `observability.sql` 155, `query_history.sql` 102, `agent_stream_schedule.sql`
60, `server_diagnostics.sql` 60, `quackapi.sql` 48, `ext_catalog.sql` 40, `telemetry.sql` 28,
`server_instance.sql` 19). Beyond install/load, views, crons and serve it carries:

- section 2, about 45 lines of `SET GLOBAL` tuning (memory, threads, http retries, cache, TimeZone)
  with commentary on every default considered;
- section 3, security settings and the `lock_configuration` at the end, which blocks `SET` on every
  client connection (the `/sql` route prepends the two allowed profiling SETs to work around it);
- section 4, `enable_logging` called twice (before and after `quackapi_serve`, which turns it off),
  four `duckdb_logs_parsed` views, and a `.read` of `server_instance.sql`;
- section 5, a `_ports` table read through scalarfs `data+varchar:`, a ports gate, four
  `SET VARIABLE`s, `quack_identify`, `_quack_serve` / `_quackapi_serve` / `_listeners` tables;
- cron registration as delete-then-insert pairs comparing job text against the file text
  (about 25 lines for two jobs), rather than a `cron.sql`;
- sections 6 and 7, `_setup_settings` snapshot plus history, and a refuse-to-serve guard.

That excess is the gap between the running file and the 40-line target. The MCP tool
definitions (182 lines of `PRAGMA mcp_publish_tool`) and the observability views are the other
large block; they belong in files the target `setup.sql` `.read`s, or in an agent's own instance.

Notes from the probes:

- `hostfs_ls` exists twice: a `CREATE OR REPLACE VIEW hostfs_ls ... FROM ls()` in `setup.sql`
  (working directory only) and an older `agents.hostfs_ls(root_path)` table macro that filters
  dot-names and `node_modules` inside the base layer. The view is the target shape; the macro
  drops information in a base layer.
- `agent.conversations` is a view, but over `agent_reader.main.conversations`, an ATTACHed second
  DuckDB (`duckdb -unsigned :memory: -cmd .read server/agent_reader.sql`, quack on 127.0.0.1:19494,
  launchd `com.inframe.agent-reader`). It is the only second-instance process running, and it is a
  workaround for an unsigned `agent_data` build, not the per-agent server flow.
- The extension catalog is real: `agents.ext_page` holds 832 raw pages, `agents.ext_docs` renders
  277 READMEs through webbed, refreshed by cron `task_0` every minute in batches of three.
- Both self-dispatch loopbacks answer from inside dev: `quack_query('quack:localhost:9494', 'SELECT 42')`
  and `http_post('http://127.0.0.1:9495/sql', ...)` returned their rows.
- `~/duckdb-skills` has `server/setup.sql` modified and about twenty untracked server files; the
  design is not yet a committed unit an agent can `git_read` and run.

## Status checklist

| element | status | evidence |
|---|---|---|
| Extension universe as `INSTALL ... FROM community; LOAD` block | DONE | 45 extensions loaded (`duckdb_extensions() WHERE loaded`); ~40 INSTALL/LOAD lines in section 1 |
| `hostfs_ls` view with every hostfs scalar over `ls()` | DONE | `duckdb_views()` shows the view; 11 scalars + `*`; `FROM ls()` is cwd-only, other dirs self-dispatch |
| shellfs views (ps, lsof) | PARTIAL | `read_lines('lsof ... \|')` returned 13 rows on dev; only `host_processes()` macro exists, no `CREATE VIEW` |
| Chrome tabs/windows views (chrome bridge, osascript) | NOT DONE | no `chrome*` relation in `information_schema.tables`; bridge described in `skills/duck/SKILL.md` only, no repo on disk |
| Extension catalog (webbed-parsed) as views + cron | DONE | `agents.ext_docs` 277 rows with readme, `agents.ext_page` 832 rows, cron `task_0` `10 * * * * *` |
| `agent_data` `read_conversations` as unmaterialized views | PARTIAL | `agent.conversations` is a view, but over ATTACHed `agent_reader` (port 19494, unsigned build), not `read_conversations` in dev |
| Agent stream cron | DONE | cron `task_1` `0 */5 * * * *`; `agent.stream_freshness` shows a run completed 06:15:38 |
| Separate `cron.sql` that setup.sql `.read`s | NOT DONE | crons registered inline via delete/insert pairs against `ext_catalog.sql`, `agent_stream_schedule.sql`, `query_history.sql` |
| Ends with quackapi serve + `/sql` route | DONE | `quackapi.sql`: `ROUTE sql POST '/sql'` loops through `quack_query`; `_listeners` = 9494/9495/9496 |
| Self-dispatch macro (later) | PARTIAL | `agents.dispatch_sql` / `dispatch_sequence` table macros exist and are MCP tools; design says mechanics first, macro later |
| setup.sql is ~40 lines of install/load/views/cron/serve | NOT DONE | 397 lines + 699 in `.read` files; SET tuning, lock, logging, ports table, settings history, guard are the excess |
| Free port found in SQL via shellfs | NOT DONE | no `~/duckdb-skills/skills/query-duckdb/`; only the sketch in this doc (Opus building in parallel) |
| Any agent starts its own DuckDB on that port from setup.sql | NOT DONE | only second process is `agent_reader.sql` on 19494, a fixed-port unsigned reader; `DEV_*_PORT` overrides exist in `_ports` but unused |
| Agents get setup.sql from git and run it | NOT DONE | `server/setup.sql` modified + ~20 untracked server files in `~/duckdb-skills`; `git_read` would return the committed, older file |
| Telemetry from each agent's DuckDB to 9494/9495 | PARTIAL | dev accepts OTLP on `/v1/*` (`otlp_events` view) and native logs archive to DuckLake every 5 min; nothing posts from a second instance |
| `query-duckdb` skill (quack_query, not ATTACH) | NOT DONE | directory absent; nearest are `skills/quack/SKILL.md` and `skills/query/SKILL.md` |
| Agents install task extensions themselves | DONE | `fakeit`, `finetype`, `jsonata`, `toml`, `vss` present in `~/.duck/extensions` beyond setup.sql's list; `autoinstall_known_extensions=false` but INSTALL FROM community works after the lock |
| Self-dispatch, http_client form | DONE | `http_post` to own `/sql` returned `[{"y":7}]`; `declarative_ls.sql` (46 lines) verified |
| Self-dispatch, quack form | DONE | `quack_query('quack:localhost:9494','SELECT 42', token := getenv('QUACK_TOKEN'))` from inside dev returned 42 |
| Light switch (kill/relaunch, watcher restart) | DONE | `~/.claude/skills/light-switch/SKILL.md`; `com.inframe.quack-reload.plist` watches `server/`; `whoami()` uptime 3 s after a save during this check |

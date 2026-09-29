---
name: query-duckdb
description: >
  How an agent writes SQL and sends it to the shared dev DuckDB (quack_query to quack:localhost:9494,
  or POST localhost:9495/sql), and how it starts its OWN DuckDB server on free ports it picks in SQL
  (own_server.sql), for work that must not share the dev process. Use before an agent's first
  statement against dev, or when it needs a private, disposable server.
---

# query-duckdb

## Send SQL to the system server (dev)

One persistent dev DuckDB serves this Mac. Never open `~/.duck/dev.duckdb` (held locked).

| door | how |
|---|---|
| HTTP | `curl -s -X POST http://127.0.0.1:9495/sql -H 'Content-Type: application/json' -d '{"sql": "SELECT 42 AS up"}'` → JSON rows. Several statements are fine; the last result returns. A SELECT with no LIMIT is capped at 20 rows, so write the LIMIT. |
| quack | from any `duckdb :memory:`: `LOAD quack; FROM quack_query('quack:localhost:9494', $q$<SQL>$q$, token := getenv('QUACK_TOKEN'));` with `QUACK_TOKEN=$(cat ~/.duck/token)` in the environment. |

`quack_query(uri, sql, disable_ssl := false, token := NULL)` takes constants only: a subquery or
column argument fails with "Table function cannot contain subqueries". Write the statement as a
value, then dispatch it with `http_post(url, headers MAP, body JSON)` to a `/sql` route (see the
telemetry block of own_server.sql).

`read_lines` is the community extension `read_lines` (not core): `INSTALL read_lines FROM community; LOAD read_lines;`.
A path ending in `|` is a shellfs command: `read_lines('lsof -nP -iTCP -sTCP:LISTEN |')`.

## Start your own server

`own_server.sql` (next to this file) runs in a fresh `duckdb :memory:`: it reads `lsof` through
shellfs, takes the two lowest free ports in 9497–9599 (`list_sort(array_agg(port))[1:2]`), serves
quack on the first and a quackapi `/sql` route on the second (127.0.0.1), prints one `_own_server`
row, and appends one row to `agents.own_server_heartbeat` on dev over quack:localhost:9494.

Launch from any DuckDB with shellfs + read_lines loaded (dollar quotes keep the nested quoting flat;
the Bash hook refuses `duckdb -init`, so the server reads the file with `-cmd '.read …'`):

```sql
FROM read_lines($c$QUACK_TOKEN=$(cat ~/.duck/token) nohup sh -c "tail -f /dev/null | /opt/homebrew/bin/duckdb :memory: -cmd '.read /Users/aloksubbarao/duckdb-skills/skills/query-duckdb/own_server.sql'" > /tmp/own_server.log 2>&1 & echo pid=$! |$c$);
```

Find your ports: `FROM agents.own_server_heartbeat ORDER BY sent_at DESC LIMIT 3` on dev, or the
`_own_server` table in `/tmp/own_server.log`. Then POST `{"sql": …}` to its `sql_url`.

Stop it: `FROM read_lines('pkill -TERM -P <pid>; echo exit=$? |');` with the `pid=` the launch
printed (the `sh`; this kills its `tail` and `duckdb` children). Confirm with
`read_lines('lsof -nP -iTCP:<port> -sTCP:LISTEN; echo lsof_exit=$? |')` → `lsof_exit=1`.

Verified 2026-09-28 (DuckDB v1.5.5): ports 9497/9498 chosen; `SELECT 42 AS up` → `[{"up":42}]`;
14 extensions loaded; heartbeat receipt 200 `[{"Count":1}]` and the row read back on dev; after
the stop, curl to 9498 exits 7 and lsof finds no listener.

## Why not `.read server/setup.sql` for a second instance

setup.sql's own ports are overridable (`DEV_QUACK_PORT`, `DEV_QUACKAPI_PORT`, `DEV_MCP_PORT`),
but it is written for the one dev process, and its includes are not:

- `server/duckdb_mcp.sql` hardcodes `http://127.0.0.1:9495/sql` (lines 20, 33, 48, 110, 118, 132):
  a second instance's MCP tools would run on dev.
- setup.sql 297: a cron posts `live.sql` to the hardcoded 9495 every 30 s.
- `server/agent_stream_schedule.sql` 59: bootstrap runs on `quack:localhost:9494` (dev).
- `server/query_history.sql` 4: ATTACHes the shared `~/.duck/lake/query-history.ducklake`.
- setup.sql 227/317: logs append to the shared `~/.duck/logs/duckdb_log.csv` unless `QUACK_NATIVE_LOG` is set.
- setup.sql 322–354: `ext_catalog`, agent-stream, query-history and observability crons start fetching and writing.

Do not edit anything under `server/`: a launchd watcher restarts dev on every change there.

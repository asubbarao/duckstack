---
name: query-duckdb
description: >
  Run SQL against the explicitly selected DuckDB, or start an agent-owned disposable DuckDB with
  its own Quack, QuackAPI and MCP endpoints. Use when choosing between shared dev and isolated work.
---

# query-duckdb

## Send SQL to the system server (dev)

Dev is the default selected service. Its database file is locked while running but disposable;
`server/setup.sql` and its included SQL are authoritative. Never open the live file directly.

| door | how |
|---|---|
| HTTP | `curl -s -X POST http://127.0.0.1:9495/sql -H 'Content-Type: application/json' -d '{"sql": "SELECT 42 AS up"}'` → JSON rows. Several statements are fine; the last result returns. A SELECT with no LIMIT is capped at 20 rows, so write the LIMIT. |
| quack | from any `duckdb :memory:`: `LOAD quack; FROM quack_query('quack:localhost:9494', $q$<SQL>$q$, token := getenv('QUACK_TOKEN'));` with `QUACK_TOKEN=$(cat ~/.duck/token)` in the environment. |

`quack_query(uri, sql, disable_ssl := false, token := NULL)` takes constants only: a subquery or
column argument fails with "Table function cannot contain subqueries". Write the statement as a
value, then dispatch it with `http_post(url, headers MAP, body JSON)` to a `/sql` route (see the
telemetry block of own_server.sql).

Self-dispatch does not need LATERAL: the source relation renders one complete statement with literal
arguments per row, scalar HTTP executes those statements, and receipts become the next relation.
Use LATERAL only for a table function that actually supports and benefits from correlation.

`read_lines` is the community extension `read_lines` (not core): `INSTALL read_lines FROM community; LOAD read_lines;`.
A path ending in `|` is a shellfs command: `read_lines('lsof -nP -iTCP -sTCP:LISTEN |')`.

## Start your own server

`own_server.sql` (next to this file) runs in a fresh `duckdb :memory:`. It reads actual listening
TCP ports through ShellFS, chooses three candidates in 9497–9599, and serves Quack, QuackAPI `/sql`
and duckdb_mcp on loopback. It prints one `_own_server` row and does not call dev. The probe cannot
reserve ports: a bind failure is authoritative, `.bail` stops startup, and the launcher reruns it.
PID inventory is not port inventory.

Launch from any DuckDB with shellfs + read_lines loaded (dollar quotes keep the nested quoting flat;
the Bash hook refuses `duckdb -init`, so the server reads the file with `-cmd '.read …'`):

```sql
FROM read_lines($c$QUACK_TOKEN=$(cat ~/.duck/token) nohup sh -c "tail -f /dev/null | /opt/homebrew/bin/duckdb :memory: -cmd '.read /Users/aloksubbarao/duckdb-skills/skills/query-duckdb/own_server.sql'" > /tmp/own_server.log 2>&1 & echo pid=$! |$c$);
```

Read the `_own_server` row in `/tmp/own_server.log`; it contains `instance_id`, `quack_uri`,
`sql_url`, and `mcp_url`. Select one explicitly for every caller.

Stop it: `FROM read_lines('pkill -TERM -P <pid>; echo exit=$? |');` with the `pid=` the launch
printed (the `sh`; this kills its `tail` and `duckdb` children). Confirm with
`read_lines('lsof -nP -iTCP:<port> -sTCP:LISTEN; echo lsof_exit=$? |')` → `lsof_exit=1`.

The instance owns no durable catalog. Its SQL definitions are replayable; raw/log publication to
object storage is a separate, explicit stage. See `docs/disposable-agent-duckdb.md`.

## Why `own_server.sql` is smaller than `server/setup.sql`

`setup.sql` ports are overridable (`DEV_QUACK_PORT`, `DEV_QUACKAPI_PORT`, `DEV_MCP_PORT`), but its
scheduled jobs and shared data products are still the dev profile. `own_server.sql` is the minimal
isolated profile. Converging both on composable profile includes is future work; do not pretend a
port override alone provides isolation.

- `server/duckdb_mcp.sql` reads the selected QuackAPI endpoint from
  `meta.runtime_endpoints`; it no longer assumes port 9495.
- setup.sql 297: a cron posts `live.sql` to the hardcoded 9495 every 30 s.
- `server/agent_stream_schedule.sql` 59: bootstrap runs on `quack:localhost:9494` (dev).
- `server/query_history.sql` 4: ATTACHes the shared `~/.duck/lake/query-history.ducklake`.
- setup.sql 227/317: logs append to the shared `~/.duck/logs/duckdb_log.csv` unless `QUACK_NATIVE_LOG` is set.
- setup.sql 322–354: `ext_catalog`, agent-stream, query-history and observability crons start fetching and writing.

Editing `server/` intentionally restarts dev. Make the source change, expect in-flight requests to
die, verify the rebuilt instance, and notify concurrent agents. That restart is acceptable locally.

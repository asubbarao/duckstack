---
name: query-duckdb
description: >
  Run SQL against dev, or start an agent-owned disposable DuckDB with its own Quack, /sql and MCP
  doors on other ports. Use when choosing between shared dev and isolated work.
---

# query-duckdb

## Dev

Dev is the default. Its doors are in /duckstack:agent-door: the MCP (`query`, `execute`),
`POST http://127.0.0.1:9495/sql` with `{"sql": "..."}` (runs the SQL untouched; a parse or bind error
is a 422 with the message), or `quack_query('quack:localhost:9494', $q$<SQL>$q$, token :=
getenv('QUACK_TOKEN'))` from any `duckdb :memory:` with `LOAD quack`. Never open
`~/.duck/dev.duckdb` directly.

`quack_query` takes constants only; a column argument fails with "Table function cannot contain
subqueries". Per-row work is /duckstack:self-dispatch.

## Your own server

`own_server.sql` (next to this file) runs in a fresh `duckdb :memory:` and serves the same three
doors on 9504 (quack), 9505 (`/sql`) and 9506 (MCP, duckdb_mcp built-ins with `execute`). It is the
dev profile without the lake, the logging, the cron and the views: for isolated work, never a silent
substitute for dev. Launch it from any DuckDB with shellfs and read_lines loaded:

```sql
FROM read_lines($c$QUACK_TOKEN=$(cat ~/.duck/token) nohup sh -c "tail -f /dev/null | /opt/homebrew/bin/duckdb :memory: -cmd '.read /Users/aloksubbarao/duckdb-skills/skills/query-duckdb/own_server.sql'" > /tmp/own_server.log 2>&1 & echo pid=$! |$c$);
```

`/tmp/own_server.log` ends with the three URLs when it is up, or with the bind error when a port
is taken (then stop whatever holds it; the ports are literals). Stop it with
`FROM read_lines('pkill -TERM -P <pid>; echo exit=$? |');` using the `pid=` the launch printed.

The instance owns no durable catalog; its SQL is replayable. Publishing anything from it is a
separate, explicit stage.

---
name: agent-door
description: >
  How any agent reaches the dev DuckDB — the one always-on database on this machine. Three doors, one
  database, no attach: the `dev` MCP (`query`, `sql` tools), POST localhost:9495/sql, or quack_query
  from your own `:memory:` DuckDB. Use before the first statement that touches dev, when a tool or port
  in your notes no longer answers, or when an agent without MCP needs to run SQL on dev.
argument-hint: "[mcp | http | quack]"
allowed-tools: Bash, mcp__dev__query, mcp__dev__sql
---

# agent-door

There is one database: `~/.duck/dev.duckdb`, held open by launchd (`com.inframe.quack`,
`~/.duck/setup.sql`). Nobody opens the file. Nobody ATTACHes it. Every door below runs your SQL
inside that one process.

| door | how | what it runs |
|---|---|---|
| `dev` MCP → `query` | tool call | one SELECT, at most 100 rows |
| `dev` MCP → `sql` | tool call | anything — DDL, DML, `COPY`, several statements; last result, at most 100 rows |
| HTTP `/sql` | `curl -s -X POST localhost:9495/sql --data-urlencode sql@file.sql` | anything, same as `sql`; JSON rows back |
| quack | `quack_query('quack:localhost:9494', $q$<SQL>$q$, token := getenv('QUACK_TOKEN'))` from `duckdb :memory:` with `LOAD quack` | anything |

Pick the first one your harness has. Claude Code has the `dev` MCP. Codex's MCP client cannot
connect to duckdb_mcp until teaguesterling/duckdb_mcp#92 ships, so Codex uses HTTP `/sql` or quack.

## The MCP is dev

duckdb_mcp runs inside the dev process itself (`setup.sql`), on 9496. `query` runs `query($sql)`
there; `sql` loops back through quack on 9494, which is what lets it run anything. There is no
second DuckDB.

## `/sql` is quackapi inside dev

`setup.sql` loads quackapi in the same process as quack and defines
`CREATE ROUTE sql POST '/sql' AS SELECT * FROM quack_query('quack:localhost:9494', $sql, …)`, so
dev can post to itself — which is what self-dispatch does (`/duckstack:self-dispatch`).

## Rules that apply at every door

- `SELECT` with `LIMIT` first, widen after. The MCP caps rows at 100.
- `getenv()` runs on dev: it reads the server's environment, not yours. Pass your own values
  (session id, paths) as literals.
- No `SET`, `INSTALL`, `LOAD` against dev — `setup.sql` owns the server's configuration.

Verified 2026-09-22: `query` returned dev tables; `query` refused `CREATE` ("Authorization
failed"); `sql` ran `CREATE TEMP TABLE …; SELECT …` and a `COPY … TO` parquet; `/sql` returned
JSON rows; `quack_query` to 9494 ran a multi-statement body.

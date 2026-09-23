---
name: agent-door
description: >
  How any agent reaches the dev DuckDB — the one always-on database on this machine. Three doors, one
  database, no attach: the `dev` MCP (`query`, `sql` tools), POST localhost:9495/sql, or quack_query
  from your own `:memory:` DuckDB. Also the task tools: git_tree and git_read (a repo through
  duck_tails), ci_hunt (an Actions log zip through duck_hunt), render (a tera template to a file),
  ext_docs, and the agent-stream tools. Use before the first statement that touches dev, when a tool or port
  in your notes no longer answers, or when an agent without MCP needs to run SQL on dev.
argument-hint: "[mcp | http | quack]"
allowed-tools: Bash, mcp__dev__query, mcp__dev__sql, mcp__dev__stream_search, mcp__dev__stream_session, mcp__dev__user_messages, mcp__dev__self_dispatch, mcp__dev__ext_docs, mcp__dev__git_tree, mcp__dev__git_read, mcp__dev__ci_hunt, mcp__dev__render
---

# agent-door

There is one database: `~/.duck/dev.duckdb`, held open by launchd (`com.inframe.quack`,
`~/.duck/setup.sql`, a symlink to `~/duckdb-skills/server/setup.sql` — every tool below is a
`PRAGMA mcp_publish_tool` there). Nobody opens the file. Nobody ATTACHes it. Every door below runs your SQL
inside that one process.

| door | how | what it runs |
|---|---|---|
| `dev` MCP → `query` | tool call | one SELECT, at most 100 rows |
| `dev` MCP → `sql` | tool call | anything — DDL, DML, `COPY`, several statements; last result, at most 100 rows |
| HTTP `/sql` | `curl -s -X POST localhost:9495/sql --data-urlencode sql@file.sql` | anything, same as `sql`; JSON rows back |
| `dev` MCP → `stream_search`, `stream_session`, `user_messages` | tool call | the agent stream — `/duckstack:agent-stream` |
| `dev` MCP → `self_dispatch` | tool call | fan a column of statements out through `/sql` — `/duckstack:self-dispatch` |
| `dev` MCP → `ext_docs` | tool call | an extension's README and page — `/duckstack:ext-catalog` |
| `dev` MCP → `git_tree(repo, ref)` | tool call | a repo on this machine's disk at a ref: `file_path, file_ext, kind, size_bytes, git_uri` — `/duckstack:duck-tails` |
| `dev` MCP → `git_read(repo, path, ref)` | tool call | one file of that repo: `file_path, text` (the ref travels in a `git://…@ref` uri) — `/duckstack:duck-tails` |
| `dev` MCP → `ci_hunt(zip, glob, format)` | tool call | `read_duck_hunt_log('zip://' \|\| zip \|\| '/' \|\| glob, format)` over a landed Actions log zip — `/duckstack:duck-hunt` |
| `dev` MCP → `render(template_path, ctx_json, out)` | tool call | `tera_render` of a template file with a JSON context, `COPY`'d to `out` — `/duckstack:one-pager` |
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
JSON rows; `quack_query` to 9494 ran a multi-statement body. `git_tree`, `git_read`, `ci_hunt` and `render` arrived
with the server `setup.sql` moving into git; if one does not answer, read its
`mcp_publish_tool` line in `~/duckdb-skills/server/setup.sql` before guessing.

---
name: agent-door
description: >
  How an agent reaches the selected disposable DuckDB: the default dev MCP, its explicit HTTP or
  Quack door, or an agent-owned in-memory instance. Also the task tools: git_tree and git_read (a repo through
  duck_tails), ci_hunt (an Actions log zip through duck_hunt), render (a tera template to a file),
  ext_docs, and the agent-stream tools. Use before the first statement that touches dev, when a tool or port
  in your notes no longer answers, or when an agent without MCP needs to run SQL on dev.
argument-hint: "[mcp | http | quack]"
allowed-tools: Bash, mcp__dev__query_with_limit, mcp__dev__query_no_limit, mcp__dev__stream_search, mcp__dev__stream_session, mcp__dev__user_messages, mcp__dev__self_dispatch, mcp__dev__ext_docs, mcp__dev__git_tree, mcp__dev__git_read, mcp__dev__ci_hunt, mcp__dev__render
---

# agent-door

## Start here

These tools are the primary agent workspace, not a last-resort database adapter.
Use `query`/`sql` for SQL, filesystem readers and ShellFS host commands. Use
`shellfs(command)` for an ordinary Bash program on the selected host; it returns
raw lines with line numbers/byte offsets, capped at 3, or an error receipt.
For structured stdout use native `read_csv`/`read_json` in query/sql. A streaming
LIMIT is a preview, not proof that every side effect completed. `render(template,
ctx)` loads a named Tera file and its siblings for includes; returns text without
executing it. If a newly published tool is absent from a client's cached list,
refresh that MCP connection; use query/sql on the same server in the meantime.

Use `self_dispatch(rows_sql)` for row-generated work: supply a SELECT with a `statement`
column and optional source keys. Filter missing work with `WHERE NOT EXISTS`;
zero rows means zero calls. The tool owns routing to the selected service.
It returns source rows, statements and raw HTTP receipts, including failures,
without a receipt-row cap. Keep batches bounded and inspect inner errors.
Use `dispatch_sequence` for dependent statements in one ordered body.
No new server, endpoint-discovery join, local engine or new macro is needed.

Dev is the default selected instance, not an institution. Its behavior comes from
`~/duckdb-skills/server/setup.sql` plus included SQL files; `~/.duck/dev.duckdb` and its WAL are
rebuildable outputs. Edit the source definition when behavior is missing, let the watcher restart
dev, and tell concurrent agents that their requests died. Do not preserve hand-created state.
Nobody opens or ATTACHes the live dev file. For isolated work, use
`skills/query-duckdb/own_server.sql`: it starts an agent-owned `:memory:` DuckDB with its own
Quack, QuackAPI and MCP endpoints.

| door | how | what it runs |
|---|---|---|
| `dev` MCP → `query` | tool call | SQL through QuackAPI; final SELECT defaults to 3 rows unless explicitly limited |
| `dev` MCP → `sql` | tool call | complete SQL bodies; same SELECT default, no limit on writes; full HTTP receipt |
| HTTP `/sql` | `curl -s -X POST localhost:9495/sql --data-urlencode sql@file.sql` | anything, same as `sql`; JSON rows back |
| `dev` MCP → `stream_search`, `stream_session`, `user_messages` | tool call | the agent stream — `/duckstack:agent-stream` |
| `dev` MCP → `self_dispatch` | tool call | fan a column of statements out through `/sql` — `/duckstack:self-dispatch` |
| `dev` MCP → `ext_docs` | tool call | an extension's README and page — `/duckstack:ext-catalog` |
| `dev` MCP → `git_tree(repo, ref)` | tool call | a repo on this machine's disk at a ref: `file_path, file_ext, kind, size_bytes, git_uri` — `/duckstack:duck-tails` |
| `dev` MCP → `git_read(repo, path, ref)` | tool call | one file of that repo: `file_path, text` (the ref travels in a `git://…@ref` uri) — `/duckstack:duck-tails` |
| `dev` MCP → `ci_hunt(zip, glob, format)` | tool call | `read_duck_hunt_log('zip://' \|\| zip \|\| '/' \|\| glob, format)` over a landed Actions log zip — `/duckstack:duck-hunt` |
| `dev` MCP → `render(template, ctx)` | tool call | `tera_render` of a template file with a JSON context, returned as text (write it with the `sql` tool's `COPY`) — `/duckstack:live-page` |
| quack | `quack_query('quack:localhost:9494', $q$<SQL>$q$, token := getenv('QUACK_TOKEN'))` from `duckdb :memory:` with `LOAD quack` | anything |

Use the configured dev MCP first. If its tools are unavailable in the harness, POST
SQL to http://localhost:9495/sql, or use quack_query against quack:localhost:9494.
These reach the same selected dev database. Give subagents the selected endpoint explicitly.
Use readers, HostFS and ShellFS through that service. Starting an agent-owned server is supported
when isolation is useful; never silently substitute it for dev when the task selected dev.

## The MCP is dev

duckdb_mcp runs inside dev on 9496. query/sql and self_dispatch send JSON to
the QuackAPI endpoint recorded by this instance, whose /sql route executes through its Quack
listener. Agents supply SQL, not connection plumbing. The `runtime` tool identifies the current
instance and endpoints; use it after a restart instead of relying on stale port assumptions.

## `/sql` is quackapi inside dev

QuackAPI is the application server inside DuckDB, not merely a SQL proxy. Treat
its routes as application endpoints: validate inputs, preserve database and HTTP
errors, define result limits, and make execution observable. MCP is the convenient
agent client; shared behavior belongs in the server so direct HTTP callers get it too.

`setup.sql` includes `server/quackapi.sql` for routes and `server/duckdb_mcp.sql`
for tools. `/sql` executes through the existing Quack listener on 9494; posting
back to this same service is self-dispatch (`/duckstack:self-dispatch`). No FastAPI
sidecar or client-owned database is needed. Keep reusable application SQL in small
included files, with state and results available as relations for human inspection.

`otlp_events` is the broad, unmaterialized telemetry relation: logs, traces and
metric shapes are unioned by name with `signal` and `metric_kind` discriminators.
Filter it for a task; preserve the native columns and raw source files.

## Rules that apply at every door

`agents.path_aliases` lists server-owned path configuration. On `/sql` and `/query`,
each request initializes ScalarFS `asubbarao.github` from the server's
`ASUBBARAO_GITHUB_ROOT`. For a committed file, use
`pathvariable:append:asubbarao.github!/claudes-console/README.md@HEAD` with a reader
inside query/sql. The underlying reader is duck_tails `git://`, not a shell fetch.
Direct Quack clients and tools outside those routes need their own session setup;
see the ScalarFS skill. A local export does not change the running server.

- MCP query/sql and the HTTP SQL routes default top-level SELECTs to 3 rows unless explicitly limited.
  LIMIT ALL explicitly opts out. Receipts identify the submitted/executed SQL
  and whether the default applied. self_dispatch does not cap work/receipt rows.
  Large results still consume memory and bandwidth.
- `getenv()` runs on dev: it reads the server's environment, not yours. Pass your own values
  (session id, paths) as literals.
- Install and load needed community extensions on the selected service. Send LOAD
  separately before batches using extension PRAGMAs or parser syntax. Inspect actual errors.
- Project scalars directly; do not cross join singleton settings CTEs. CROSS JOIN
  UNNEST(arr) is allowed; other expansion needs a relational purpose.

Verified 2026-09-29: dev rebuilt from setup.sql and reported a fresh instance identity and selected
endpoints. For missing
task tools, inspect mcp_publish_tool definitions in ~/duckdb-skills/server/duckdb_mcp.sql.
Check transport status and actual SQL results; never replay an uncertain write.

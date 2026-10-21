---
name: agent-door
description: >
  How an agent reaches the dev DuckDB: the dev MCP (query, query_full, execute), HTTP /sql, or Quack.
  Use before the first statement that touches dev, when a tool or port in your notes no longer answers,
  or when an agent without MCP needs to run SQL on dev.
argument-hint: "[mcp | http | quack]"
allowed-tools: mcp__dev__query, mcp__dev__query_full, mcp__dev__execute
---

# agent-door

Dev is one DuckDB process defined entirely by `~/duckdb-skills/server/setup.sql`. Saving that file
restarts it (every MCP session drops); `~/.duck/dev.duckdb` is a rebuildable output.

| door | how | runs |
|---|---|---|
| `dev` MCP → `query(sql)` at `http://localhost:9495/mcp/` | tool call | any SQL, posted to `/sql` unchanged; the reply is capped at 50 complete rows / 8 KiB as `{rows, returned_rows, total_rows, truncated, reason, row_limit, byte_limit}`. Use ORDER BY for a meaningful prefix. |
| `dev` MCP → `query_full(sql)` | tool call | any SQL unchanged, the complete reply; use when the result size is understood. |
| `dev` MCP → `execute(statement)` | tool call | any SQL unchanged, the complete reply: COPY, DDL, DML, LOAD, readers and ShellFS. COPY writes every source row. |
| HTTP `/sql` | POST JSON `{"sql": "…"}` to `http://127.0.0.1:9495/sql` | any SQL, run untouched; a parse or bind error is HTTP 422 with the message. |
| quack | `quack_query('quack:localhost:9494', $q$<SQL>$q$, token := getenv('QUACK_TOKEN'))` from a `:memory:` DuckDB with `LOAD quack` | any SQL |
| HTTP `/inbox` | POST any JSON to `http://127.0.0.1:9495/inbox` | lands as a row in `quackapi_jobs` (queue `inbox`, `payload` JSON); 201 with the id |
| OTLP | POST OTLP/HTTP JSON to `http://127.0.0.1:4318/v1/logs`, `/v1/traces`, `/v1/metrics` | rows in `otlp_logs`, `otlp_traces`, `otlp_metrics_*` |
| Prometheus | GET `http://127.0.0.1:9495/metrics` | `meta.prometheus_metrics` as text |

Use the MCP first. If its tools are missing in the harness, POST to `/sql` or use quack; all three
reach the same database. Give subagents the endpoint explicitly.

## Task recipes (plain SQL, no special tools)

| task | SQL |
|---|---|
| agent conversations | `read_conversations(source := 'claude', path := getenv('HOME') \|\| '/.claude')`, see `/duckstack:agent-stream` |
| a repo at a ref | duck_tails `git_tree(repo, ref)` / `git_read(...)` / `git://` paths, see `/duckstack:duck-tails` |
| a CI log zip | `read_duck_hunt_log('zip://' \|\| zip \|\| '/' \|\| glob, format)`, see `/duckstack:duck-hunt` |
| a tera template | `tera_render(template, ctx::JSON, autoescape := false)`, see `/duckstack:tera` |
| an extension's README | `agents.ext_catalog`, see `/duckstack:ext-catalog` |
| telemetry | `otlp_logs`, `otlp_traces`, `otlp_metrics_gauge` / `_sum` / `_histogram` (what arrived on 4318) |
| events posted to `/inbox` | `quackapi_jobs WHERE queue = 'inbox'` |

## Rules at every door

- `getenv()` runs on dev: it reads the server's environment, not yours. Pass your own values as literals.
- `LOAD x` is its own statement before a batch that uses the extension's PRAGMAs or parser syntax.
- `INSTALL x FROM community; LOAD x;` whenever a function is missing.
- Check the receipt body, not just the status; never replay an uncertain write.
- For isolated work, `skills/query-duckdb/own_server.sql` starts an agent-owned `:memory:` DuckDB;
  never substitute it silently for dev.

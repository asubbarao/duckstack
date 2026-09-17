---
name: agent-door
description: >
  What the `dev` MCP sidecar (duckdb_mcp on http://localhost:9496/mcp) can actually reach and
  how to call it — including the raw JSON-RPC form for debugging. Use when an agent only has
  MCP access, when a `dev.<table>` lookup through MCP says the table does not exist, when
  deciding between the MCP door and a quack attach, or when reviewing/changing mcp-setup.sql.
argument-hint: "[probe | call <tool> <json> | review]"
allowed-tools: Bash
---

The agent door is a second launchd-owned DuckDB (`com.inframe.mcp`, `~/.duck/mcp-setup.sql`)
whose main database is a throwaway `~/.duck/scratch.duckdb`, with `dev` attached `READ_ONLY`
through the gated 9495 listener, serving duckdb_mcp over HTTP on 9496. Registered as the `dev`
MCP in `~/.claude.json` and `~/.codex/config.toml`. Everything below was verified against the
running sidecar on 2026-09-17 (duckdb_mcp a6b8648 = v2.3.0, quack c154811, DuckDB 1.5.5).

## What is reachable — the part the docs do not tell you

| Through the `query` tool | Result |
|---|---|
| `SELECT * FROM dev.query($$SELECT … FROM some_dev_table$$)` | **works** — the only way to read dev |
| `SELECT * FROM dev.some_dev_table` | **fails**: "Catalog Error: Table … does not exist" — the quack attach mirrors no catalog |
| `list_tables`, `database_info`, `FROM duckdb_tables()` | scratch only (`_mcp_server_config`, `_mcp_server_status`, `agent_scratch`, the `mcp_*_log` views) |
| `dev.query($$CREATE …$$)`, `quack_query(...)` writes, `ATTACH`, `LOAD`, `SET` | refused — server gate on 9495 (parse = exactly one SELECT) plus the sidecar's tool policy (`execute_allow_load/attach/set false`) |
| unqualified `CREATE TABLE t AS …` via `execute` | lands in **scratch**; that is the point — a rogue `DROP … CASCADE` costs nothing |
| `read_text('~/.duck/token')` etc. | refused — `enable_external_access = false`; `allowed_directories` = `~/inframe`, `~/.duck/ingest`, `~/.duck/logs` |

So an agent on the door lists dev tables with
`SELECT * FROM dev.query($$SELECT table_name, estimated_size FROM duckdb_tables() WHERE NOT internal$$)`
and reads them with `dev.query($$…$$)` — joins included, since the join then runs on dev.
Each tool call is a **fresh connection**: no TEMP tables or variables survive between calls;
put the whole thing in one `dev.query`.

## Tools exposed (tools/list, live)

`query` (read-only SELECT; `format`: json | jsonl | csv | markdown, default markdown),
`describe`, `list_tables`, `database_info`, `export` (file output **off**), `execute`
(DDL/DML into scratch; LOAD/ATTACH/SET off). No custom tools are published yet.

## Calling it raw (debugging, or from a shell without an MCP client)

```bash
curl -s http://localhost:9496/health                                   # {"status":"ok"}
curl -s -X POST http://localhost:9496/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
curl -s -X POST http://localhost:9496/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"query","arguments":{"sql":"SELECT * FROM dev.query($$FROM whoami()$$)","format":"markdown"}}}'
```

No auth header: `require_auth false`, loopback only. Errors come back as JSON-RPC `error`
objects with the DuckDB message (`code -32003` for SQL errors).

## `probe` — is it up, what does it think it is

```bash
curl -s -X POST http://localhost:9496/mcp -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query","arguments":{"sql":"SELECT * FROM mcp_server_config()","format":"markdown"}}}'
```

`request_timeout_seconds 30` and `max_connections 10` **appear** in that output and are
**not enforced** by a6b8648 — it reports fields it does not parse. Do not represent 30 s as a
ceiling; there is none below the launchd process itself. After a planned dev restart, restart
the sidecar too so it re-establishes the 9495 attachment.

## `review` — the sidecar against the duckdb_mcp docs (main, 23 commits ahead of a6b8648)

Findings to carry into any change of `~/inframe/internal/duckdb/agent-gateway/mcp-setup.sql`:

1. **Markdown cells with newlines split rows in a6b8648.** `default_result_format` is
   `markdown`; upstream's unreleased fix (#84) notes `EscapeMarkdownCell()` escaped only `|`, so
   a cell containing `\n` (every `html.document`, every readability text) renders as extra
   rows/columns and row counts change silently. Until the sidecar ships a build with that fix,
   agents reading page text through the door should request `format: "json"` or select
   bounded scalar columns (`len(...)`, `title`) rather than bodies.
2. **A failed `mcp_publish_*` used to report a successful start** (#84, fixed on main).
   Irrelevant today (nothing is published) but relevant the moment a curated tool is added.
3. **The blind `list_tables` is fixable without raw SQL.** `mcp_publish_tool` accepts `$param`
   inside table-function arguments and `dev.query` is a table function, so a curated
   `dev_tables` tool (`SELECT * FROM dev.query('SELECT table_name … FROM duckdb_tables()')`)
   and a `dev_describe` tool (`… DESCRIBE $table …` via `format`) would give agents a catalog
   without handing them `execute`. `builtin_tools: false` + `enable_query_tool: true` would then
   shrink the surface to `query` + curated tools. Not applied here — it is a `setup`-side change.
4. **`export_allow_file_output false` is right** and `execute`'s lack of a file denylist is
   covered only by `enable_external_access = false` — keep the `ATTACH`-before-`external_access`
   ordering exactly as the file has it (`getenv()` dies after that line).
5. **stdio is not used** (HTTP transport), so the `.mode trash` / fd-1 ownership fixes on
   main do not apply; keep `.mode trash` anyway for a clean init log.
6. **`mcp_lock_servers = true` then `lock_configuration = true`** after `background: true`
   start — matches the documented init-script pattern; nothing to change.
7. Extension pin: the shipped binary is 23 commits behind main, "mostly silent-corruption
   fixes" (JSON/CSV escaping, response-id correlation, glob paging). Re-verify at 2.0.0
   (2026-10-21) per the README; do not `UPDATE EXTENSIONS` on a running server.

## `call <tool> <json>`

Wrap the given tool name and arguments in the JSON-RPC envelope above, POST, print the
`result.content[0].text`. For `query`, default `format` to `json` when the SQL can return
text bodies (finding 1), `markdown` otherwise.

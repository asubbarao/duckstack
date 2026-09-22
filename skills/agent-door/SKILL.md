---
name: agent-door
description: >
  Discover and use the planned native System Quack MCP server at 127.0.0.1:9496/mcp. Use for
  MCP tool discovery, actual input schemas, and native-tool routing; not for old sidecar repair.
argument-hint: "[discover | tool-name | runtime-check]"
---

# Native `duckdb` MCP door

The source package targets a user-wide MCP server named `duckdb` at
`http://127.0.0.1:9496/mcp`. It is planned to run inside the same DuckDB process as Quack
(`127.0.0.1:9494`) and QuackAPI (`127.0.0.1:9495`), against the same `main.duckdb` instance.
It replaces the old scratch-database sidecar. The runtime is not deployed or accepted yet, so a
documented endpoint, port, or historical probe is not current health evidence.

## First action: discover the live contract

When the native endpoint is configured and reachable, call `tools/list` before selecting a tool.
Treat the returned name, description, required fields, and `inputSchema` as authoritative. Do not
infer a signature from this skill, an old MCP cache, or duckdb_mcp built-ins. On failure, report
the native endpoint unavailable; never redirect work to an old sidecar, a scratch database, or a
different localhost port.

The planned SQL publication has exactly these 14 tools. This is a deployment expectation to
compare with `tools/list`, not a claim that they are live:

| Tool | Planned input |
|---|---|
| `quack_query` | `sql: string` — one complete body; defaults to `workspace` |
| `hostfs`, `is_file`, `is_dir`, `file_name`, `file_extension`, `file_size`, `absolute_path`, `path_exists`, `path_type`, `file_last_modified` | `path: string` |
| `pwd`, `path_separator` | no arguments |
| `hsize` | `bytes: string` decimal integer |

`quack_query` returns an envelope containing `rows`, `rows_returned`, and `capped`; its planned
limit is 10,000 rows. A capped response is successful but incomplete—narrow, aggregate, or land
the result before asking for more. SQL errors remain tool errors. Do not automatically replay a
write whose outcome is unknown after a disconnect or timeout.

## SQL through `quack_query`

Use a complete body and write it as server-local SQL. The tool selects `workspace` first; qualify
`main` or `public` only with explicit task authorization. Discover functions and extensions in
the live instance before invoking them:

```sql
DESCRIBE SELECT * FROM duckdb_extensions();
FROM duckdb_extensions() ORDER BY extension_name;
DESCRIBE SELECT * FROM duckdb_functions();
FROM duckdb_functions() WHERE function_name = '<function>';
```

Routine reads/workspace writes and `INSTALL`/`LOAD` are authorized. Install/load through this
tool when needed, verify `duckdb_extensions()` and the actual function signature, then make one
bounded invocation. `main`/`public` changes require the task's explicit authorization.

## Runtime acceptance, when separately authorized

A deployment check must verify all 14 discovered tool names and schemas, a workspace-default
query, a scoped write, extension install/load/signature/use, Quack, QuackAPI, and MCP health.
That check is not authorized merely by editing this source package. Do not call raw JSON-RPC or
restart a service as a substitute for a configured native MCP client acceptance test.

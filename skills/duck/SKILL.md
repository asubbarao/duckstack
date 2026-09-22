---
name: duck
description: >
  System Quack execution boundary and SQL process rules. Use before DuckDB, Quack, QuackAPI,
  native duckdb MCP, extension, ShellFS, or cronjob work on this machine.
argument-hint: "[boundary | tools | extensions | shellfs | cronjob]"
---

# System Quack

The planned runtime is one launchd-owned DuckDB process opening `main.duckdb`. It exposes
Quack at `quack:127.0.0.1:9494`, QuackAPI at `http://127.0.0.1:9495`, and the user-wide native
MCP server named `duckdb` at `http://127.0.0.1:9496/mcp`. These interfaces share one database
instance. This topology is a source-package target, not evidence that it is deployed or healthy.

For routine agent work, use the native `duckdb` MCP tool `quack_query(sql)`. Supply one complete
SQL body. The tool prepends the workspace selection, so unqualified objects resolve in writable
`workspace`; qualify another schema when that is intentional. Do not start a sidecar, recreate
startup or telemetry machinery, attach a scratch database, or substitute another loopback
endpoint after a failure.

## Discover before relying on a capability

At the start of a new runtime-dependent task, obtain the native MCP `tools/list` result and use
its input schemas as the current tool contract. Then use `quack_query` to inspect the live SQL
surface, not a remembered extension/version list:

```sql
DESCRIBE SELECT * FROM duckdb_extensions();
FROM duckdb_extensions() ORDER BY extension_name;

DESCRIBE SELECT * FROM duckdb_functions();
FROM duckdb_functions()
WHERE function_name IN ('<function>', '<other_function>')
ORDER BY function_name;
```

Inspect the fields returned by that runtime before choosing parameter names, defaults, or overloads.
If an extension is missing, agents may install and load it through the same MCP tool, including
community extensions, then repeat the function inspection and a bounded working invocation:

```sql
INSTALL <extension> FROM community;
LOAD <extension>;
FROM duckdb_extensions() WHERE extension_name = '<extension>';
```

`INSTALL` changes the service extension cache and `LOAD` is process-wide state: report both.
Do not invent a server bootstrap, another persistent process, or a substitute endpoint to make an
extension available. A disconnect or timeout does not prove rollback; inspect committed state
before considering any retry of a write.

## Authorization and persistence

- Reads, workspace writes, and extension installation/loading are authorized routine work.
- Changes in `main` or `public` require explicit authorization in the current task. Once given,
  do not ask again for the same authorized work.
- All durable tables, views, secrets, routes, and scheduled jobs belong to the selected service,
  never a local state file or a long-lived client session.
- A local `duckdb :memory:` process is only an ephemeral orchestrator. It may call an explicitly
  selected Quack endpoint or local service, but never silently replaces System Quack.

## Process rules

- Use complete, independently rerunnable SQL bodies. Preserve raw external responses and query
  a bounded slice before widening work.
- Do not claim a server query deadline from client or configuration text alone. A client timeout
  only bounds waiting unless the running implementation is verified to enforce cancellation.
- ShellFS is allowed only as an explicit, bounded pipeline: show the complete command, inputs,
  output shape, and termination condition. Never hide a pipe in a macro, state helper, or
  background recreation loop.
- A cronjob is allowed only as explicit scheduled SQL: state the schedule, complete body, target
  tables, idempotency, and cancellation/inspection path. Do not recreate legacy startup jobs.
- `crawl_url` and `read_lines_lateral` require an explicit correlated form such as
  `input_relation CROSS JOIN LATERAL function(input_relation.column)`. Preserve timeout,
  workers, batch size, delay, link following, depth, cache, and result limits for every crawl.

## Route selection

| Need | Route |
|---|---|
| normal System Quack read/write or extension work | native `duckdb.quack_query(sql)` |
| inspect the published MCP surface | `/duckstack:agent-door` |
| explicit Quack protocol orchestration | `/duckstack:quack` |
| a file or explicitly named non-System-Quack database | `/duckstack:attach-db` |
| per-row table-function dispatch | `/duckstack:self-dispatch` |

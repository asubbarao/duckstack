---
name: attach-db
description: >
  Select and inspect an explicitly named non-System-Quack database, Quack URI, or Superhuman Docs
  document. System Quack itself uses native duckdb MCP quack_query(sql), not client ATTACH.
argument-hint: "[duckdb | quack:host:port | superhuman:<doc-id> | path.duckdb] [--as alias]"
---

# Choose an explicit target

Read `/duckstack:duck` first. The default `duckdb` target is System Quack: use native
`duckdb.quack_query(sql)`, which defaults to `workspace`. Do not attach its database file, its
Quack endpoint, a scratch database, or an old telemetry database from a local client.

For any other target, require an explicit argument; never treat a failed System Quack connection
as permission to select another localhost service.

| Target | Action |
|---|---|
| `duckdb` or empty | discover native tools, then call `quack_query` with a complete body |
| `quack:host:port` | use `/duckstack:quack` with that explicit URI and its authorized credential |
| `superhuman:<doc-id or URL>` | load/install `superhuman_docs` in the selected local client, create a secret from an approved token source, then attach the document |
| `<path>.duckdb` | attach read-only only after confirming no service owns the file |

For a file target, probe the path and use an explicit alias. A lock error means another process
owns it: report that owner/target rather than opening it read-write or substituting a different
database.

For a System Quack catalog inspection, send this complete body through native `quack_query`:

```sql
SELECT database_name, schema_name, table_name, estimated_size, column_count
FROM duckdb_tables()
WHERE NOT internal
ORDER BY database_name, schema_name, table_name;
```

Then inspect only task-relevant tables with `DESCRIBE <qualified_table>`. For an extension-backed
target, inspect `duckdb_extensions()` and `duckdb_functions()` in its actual execution process
before choosing syntax; install/load missing extensions through the authorized native MCP route
when System Quack is selected.

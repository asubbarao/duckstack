---
name: quack
description: >
  Run complete SQL bodies through System Quack. Prefer native duckdb MCP quack_query(sql); use
  an explicitly selected Quack URI only for deliberate DuckDB-to-DuckDB orchestration.
argument-hint: "[send <sql> | probe]"
---

# Quack bodies, not client sessions

For normal System Quack work, call the native MCP tool `duckdb.quack_query` with one complete SQL
body. It selects `workspace` before the body runs. There is no `ATTACH`, alias, scratch database,
state file, startup recreation, or legacy client query wrapper in this path.

```sql
CREATE TABLE IF NOT EXISTS task_results AS
SELECT 42 AS answer;
FROM task_results;
```

Objects in `main` or `public` require explicit task authorization; workspace writes and routine
extension installation/loading are already authorized. Do not retry a write after an ambiguous
timeout or disconnect until a read of committed state resolves the outcome.

## Discover extensions and signatures first

Before relying on an extension or an overload, inspect it in the same complete body or an earlier
bounded body:

```sql
FROM duckdb_extensions() WHERE extension_name = '<extension>';
DESCRIBE SELECT * FROM duckdb_functions();
FROM duckdb_functions() WHERE function_name = '<function>';
```

Missing extensions may be installed and loaded through `quack_query`:

```sql
INSTALL <extension> FROM community;
LOAD <extension>;
FROM duckdb_extensions() WHERE extension_name = '<extension>';
```

Report the process-wide state change, inspect the returned signature fields, and make a bounded
working call. Do not infer a function signature from a package note.

## Explicit protocol orchestration

Only when a task explicitly selects a Quack URI, an ephemeral local DuckDB client may load Quack
and use its actual signature:

```sql
LOAD quack;
FROM quack_query(
    'quack:127.0.0.1:9494',
    $$SELECT current_database(), current_schema()$$,
    token := getenv('QUACK_TOKEN')
);
```

This is a stateless protocol call. Do not use it to substitute another endpoint when the native
MCP fails, and do not use `ATTACH` to establish an ordinary System Quack session. Use named dollar
delimiters when an embedded body itself contains `$$`.

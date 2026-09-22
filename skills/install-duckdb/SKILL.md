---
name: install-duckdb
description: >
  Inspect, install, load, and verify DuckDB extensions through native System Quack MCP. Use for
  a missing extension or an explicit extension update; do not create a local server substitute.
argument-hint: "[--update] [extension | extension@repository ...]"
---

Read `/duckstack:duck` first. The planned native MCP tool is `duckdb.quack_query(sql)`, whose
complete SQL body defaults to `workspace`. This source package is not proof the runtime is live;
discover the native tools and inspect the running service before changing it.

## Inspect first

Call native `tools/list`, then use `quack_query` to inspect the real extension catalog and the
function fields available in this process:

```sql
DESCRIBE SELECT * FROM duckdb_extensions();
FROM duckdb_extensions() ORDER BY extension_name;
DESCRIBE SELECT * FROM duckdb_functions();
```

For each requested `name` or `name@repository`, query its existing row. Do not use a remembered
cache location or a local CLI as evidence about the service.

## Install, load, verify

Routine installation/loading is authorized. Use a complete native body, prefer named dollar
delimiters for nested SQL, and report both operations because they affect the service:

```sql
INSTALL <name> FROM <repository>;
LOAD <name>;
FROM duckdb_extensions() WHERE extension_name = '<name>';
FROM duckdb_functions() WHERE extension_name = '<name>' ORDER BY function_name;
```

For a core extension omit `FROM <repository>`. Inspect the returned function signature fields,
then make one bounded working invocation using the actual parameter names/defaults. A `LOAD` is
process-wide; an extension update or force install may need separately authorized runtime restart
before a loaded binary can change. Never recreate launchd, startup SQL, a sidecar, or telemetry to
make an extension work.

`--update` requires an explicit requested extension/update scope. Inspect installed metadata
before and after, preserve the exact error on failure, and do not claim an update/restart happened
unless it was actually verified in the running service.

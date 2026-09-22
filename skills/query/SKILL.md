---
name: query
description: >
  Run SQL through native System Quack MCP, or query explicitly named local files. System Quack
  requests use duckdb.quack_query(sql) with one complete body and default to workspace.
argument-hint: "<SQL | question | path.sql> [--file data-path] [--target duckdb]"
---

Read `/duckstack:duck` first.

## Select the route

- **System Quack (default):** discover `duckdb` MCP tools, then call `quack_query(sql)`. Send a
  complete SQL body; unqualified names resolve in `workspace`.
- **Artifact:** read the `.sql` file, honor `--#` instructions, then pass its complete contents to
  `quack_query`. Keep it as one durable, reviewable SQL artifact—never a state file or startup
  fragment.
- **Local file:** only when `--file` or an explicit file path selects it. Use an ephemeral local
  DuckDB client with a narrow `allowed_paths` list. This does not create or substitute a service.
- **Another endpoint/database:** require an explicit target and use `/duckstack:attach-db`; never
  fall back to it after a native MCP failure.

The target runtime is planned, not deployed. If native tool discovery or invocation fails, report
that failure and stop; do not repair it by starting a sidecar, rebuilding startup/telemetry state,
or routing to a different port.

## Discover the actual SQL surface

Before generating extension-specific SQL, inspect the running catalog through a bounded complete
body:

```sql
DESCRIBE SELECT * FROM duckdb_extensions();
FROM duckdb_extensions() ORDER BY extension_name;
DESCRIBE SELECT * FROM duckdb_functions();
FROM duckdb_functions() WHERE function_name = '<function>';
```

Use the returned fields to select signatures and named parameters. Missing extensions may be
installed and loaded through native `quack_query`, including community extensions; report the
process-wide change, re-inspect it, and verify a bounded call. Routine reads/workspace writes and
extension installation/loading are authorized. `main` or `public` changes need explicit current
task authorization and never need repeated approval once granted.

## Generate and execute

- Start with task-named tables and `DESCRIBE`; do not infer schema from position, filenames, or
  JSON/string surgery. Keep raw data/provenance, use CTEs, and widen from a bounded probe.
- Prefer typed extension functions and all named parameters after inspecting their real signature.
  `regexp_*` needs user approval.
- Keep relational fan-out. When a table function rejects a column parameter, use
  `/duckstack:self-dispatch`; never replace it with a loop or lossy aggregation.
- State every crawl's timeout, workers, batch size, delay, link-following, depth, cache, and
  result limits. Preserve raw failures; an HTTP error page is not a new seed.
- ShellFS requires an explicit bounded pipeline. cronjob requires explicit scheduled SQL with
  schedule, body, target, idempotency, and inspection/cancellation path.

For multi-line or nested SQL, use dollar delimiters in the artifact/body (`$$...$$` or a named
delimiter such as `$body$...$body$`) instead of backslash-escaped quote soup.

Inspect the result envelope: `capped = true` means its first 10,000 rows are not the whole
result. Narrow or land a result before proceeding. A timeout/disconnect does not establish
rollback; inspect committed state before retrying a write. Present the exact SQL and a concise
interpretation.

## Local-file shape

```sql
SET allowed_paths = ['<explicit-path>'];
SET enable_external_access = false;
SET allow_persistent_secrets = false;
SET lock_configuration = true;
FROM '<explicit-path>' LIMIT 100;
```

List every permitted path. Do not open service-owned `.duckdb` files locally.

## DuckDB Friendly SQL Reference

- Use FROM-first, `GROUP BY ALL`, `ORDER BY ALL`, `SELECT * EXCLUDE`/`REPLACE`, `UNION ALL BY
  NAME`, `QUALIFY`, `PIVOT`/`UNPIVOT`, `DESCRIBE`, and `SUMMARIZE` where they clarify intent.
- Prefer `array_agg(x) AS xs, len(xs) AS n` in base layers when enumeration matters; do not use
  a lossy aggregate as a proxy for unseen rows.
- Use `format()` for structured statement construction, not concatenated quote escapes. A
  statement generated per row remains data until a permitted self-dispatch route executes it.
- Lateral calls must be correlated: `FROM seeds CROSS JOIN LATERAL f(seeds.value)`.
- For writes, use explicit targets and idempotent shapes such as `CREATE OR REPLACE TABLE` or
  `INSERT ... BY NAME` only when their overwrite/update semantics match the task.

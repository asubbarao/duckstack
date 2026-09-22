---
name: self-dispatch
description: >
  Preserve relational per-row fan-out when a DuckDB table function cannot bind a column argument.
  Use explicit QuackAPI or ShellFS dispatch only after the direct relation form is impossible.
argument-hint: "[quackapi | shellfs | quack] [what varies per row]"
---

# Self-dispatch is a bounded SQL technique

Use native `duckdb.quack_query(sql)` for the complete body. It defaults to `workspace`. First
inspect the actual function signature with `duckdb_functions()` and try the direct relational or
explicit-list form. Dispatch is justified only by the observed binder limitation, for example a
table function rejecting a lateral column parameter.

The planned System Quack topology is one process: Quack `127.0.0.1:9494`, QuackAPI
`127.0.0.1:9495`, native MCP `127.0.0.1:9496/mcp`. This is not deployment evidence. Do not
create a sidecar, a scratch database, an old telemetry process, or a substitute endpoint.

## Shape

1. Keep the generated statements as a relation: `stmts(q, source_key, ...)`.
2. Build each statement with `format()` and named dollar delimiters where necessary; preserve the
   source key and raw failure body.
3. Fire through an explicitly authorized loopback executor, use `array_agg` as the completion
   barrier, then `UNNEST ... WITH ORDINALITY` to retain correspondence and order.
4. Gate on each response status before parsing; a failed request is a result row, not absence.
5. Land durable outputs in `workspace` unless the task explicitly authorizes another schema.

## Allowed executors

**QuackAPI.** Use only a route that the current task explicitly creates or names, and only after
discovering the installed `quackapi` signatures through MCP. The route and listener share the
selected System Quack process; never post SQL to the Quack protocol port. Keep loopback URLs,
route body, schema changes, and cleanup explicit. A route is persistent/process-visible state,
so report it.

**ShellFS.** Use only an explicit, bounded pipeline. The command text, source relation, output
reader schema, stderr/error capture, and termination condition must appear in the SQL artifact.
Do not generate a shell state helper, detached job, hidden temporary script, or recursive pipe.

**Quack loopback.** For one complete body built from constants, an explicitly selected
`quack_query('quack:127.0.0.1:9494', $body$...$body$, ...)` may be appropriate inside the
service. It is not a per-row executor and never substitutes a failed native MCP request.

## Scheduling and safety

Cron is separate from dispatch. A cronjob must be explicit scheduled SQL with its schedule,
complete body, idempotency key, target tables, and inspection/cancellation query. Do not use
cronjob or ShellFS to recreate historical startup, sidecar, or telemetry behavior.

Routine workspace writes, reads, and extension installation/loading are authorized. `main` or
`public` mutations require explicit task authorization. For an unknown write outcome, inspect the
durable result before any retry.

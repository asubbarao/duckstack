---
name: self-dispatch
description: Execute row-generated SQL through the selected DuckDB MCP. Use for per-row SQL, file, ShellFS or HTTP work and literal-argument or unsupported lateral table-function errors.
argument-hint: "[source SELECT with a statement column]"
allowed-tools: mcp__dev__self_dispatch, mcp__dev__dispatch_sql, mcp__dev__dispatch_sequence, mcp__dev__query_with_limit, mcp__dev__query_no_limit
---

# Self-dispatch

Use the selected DuckDB MCP as the primary workspace. Agents submit SQL; the
tool handles routing to the existing service. No new server, local engine,
endpoint discovery, or new macro is needed.

- `query(sql)` / `sql(sql)`: ordinary SQL, native readers and ShellFS host commands.
- `self_dispatch(rows_sql)`: a SELECT producing `statement` and optional source keys.
  Only returned rows execute. Zero rows means zero calls.
- `dispatch_sql(statements)`: an existing list of independent SQL statements.
- `dispatch_sequence(statements)`: dependent statements in one ordered body.
  No implicit transaction or retry; inspect state after failure.

## Missing work is a WHERE

Pass this SELECT to `self_dispatch(rows_sql)`:

```sql
SELECT $$SELECT cron('CHECKPOINT;', '30 * * * * *')$$ AS statement
WHERE NOT EXISTS (
  FROM cron_jobs()
  WHERE query = 'CHECKPOINT;' AND schedule = '30 * * * * *'
);
```

The statement stays text until the missing-row test passes. The installed
`cron()` incorrectly reports no side effects: a direct constant call can run
during planning even when its WHERE returns no rows. This dispatch form was
tested with a missing job and a repeat call: one registration, then no call.
It is not an atomic uniqueness guarantee for simultaneous callers.

## A shortcut is not the mechanism

The operation is ordinary SQL posting a generated statement back to the selected
service. If a tool, template, route alias or macro fails, inspect its error and
use the plain scalar POST form below on the same service. Do not infer that
self-dispatch is unavailable, create a new server, or retry an uncertain write.
Tera is optional; use it only for actual repeated syntax. No new macros.

Working alternatives are in `~/duckdb-dataswarm/duckdb/examples/selfdispatch.sql`:
JSON POST, form POST, curl, ShellFS curl, HTTP MCP, zero-row gating, and optional
Tera/AppleScript rendering. The `/q` route sketch is explicitly not installed.

## Raw receipts

`self_dispatch` returns `source`, `statement`, `status`, `body`, and the full
`response`. It retains all input columns under source and does not cap receipt
rows. Keep raw responses before deriving typed rows. Inspect failures too;
HTTP success alone does not prove the intended data or effects.

Use bounded batches: large response arrays can exhaust memory. The primary
query/sql and self_dispatch tools use JSON requests (20 KB SQL verified), not
the form path that rejected roughly 8 KB. The installed MCP JSON formatter
encodes cells as strings. QuackAPI ed4552b preserves DuckDB errors in the HTTP
body; keep both status/reason and that body. Never replay an uncertain write.

For results consumed by subsequent SQL stages, use the plain-SQL molecule in
`~/duckdb-dataswarm/skills/self-dispatch/SKILL.md`: source rows → statements →
scalar POSTs to the explicitly selected service → array → CROSS JOIN UNNEST.
Keep source keys, statements and raw receipts. Ordinality is metadata, not
execution ordering. Use one ordered body or actual dependencies for ordering.

Canonical implementation: `~/duckdb-dataswarm/duckdb/mcp/self_dispatch.sql`.
Dev startup registration: `~/duckdb-skills/server/setup.sql`.
Historical standalone examples in `references/` are not the dev execution path.

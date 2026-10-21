---
name: query
description: >
  Run SQL on dev through its MCP: every tool runs any SQL unchanged; `query` caps the reply at 50 rows
  and 8 KiB, `query_full` and `execute` return it whole. If the MCP is
  missing from the harness, POST the same SQL to dev's /sql or use quack_query. Explore with live
  queries; save a .sql once its shape is proven.
argument-hint: <SQL | question | path.sql>
allowed-tools: mcp__dev__query, mcp__dev__query_full, mcp__dev__execute
---

# Query dev

Read /duckstack:agent-door for the doors and /duckstack:duck for the SQL rules.

- All three tools post the SQL to `/sql` unchanged, so each takes anything `/sql` takes: SELECT,
  `PIVOT … ON key` without an IN list, `LOAD`, DDL, `COPY`, readers, ShellFS, several statements.
  Only the reply differs. With several statements `/sql` returns one result set (2026-10-20:
  `SELECT 1 AS a; SELECT 2 AS b` gave `a`, `LOAD json; SELECT 2 AS b` gave `b`).
- `query(sql)`: the reply is `{rows, returned_rows, total_rows, truncated, reason, row_limit: 50,
  byte_limit: 8192}`. `rows` is the longest prefix of complete rows within 50 rows and 8 KiB of
  text (256 bytes are kept for the other fields); a row is never cut inside a value. `total_rows`
  is the full count, `truncated` is `returned_rows < total_rows`, and `reason` is `row_limit`,
  `byte_limit`, `oversized_row` (the first row alone is over 8 KiB) or null. A statement with no
  result set (`LOAD`, most DDL) gives `rows: []` and `total_rows: 0`.
- The cap is on the reply only: dev runs the whole statement and builds the whole result first
  (1.6 MB for 100k rows), so it bounds context, not work or memory. Use `ORDER BY` for a
  meaningful prefix.
- `query_full(sql)` and `execute(statement)`: the complete `/sql` reply, no cap. Use them when the
  result size is understood, and `execute` for `COPY` and writes by habit. Service timeout and
  transport caps still apply.
- A failed statement is `isError: true` with the DuckDB message in `detail`; under `query` a
  message over 8 KiB is cut to 512 characters with `truncated: true`.
- Without the MCP: `POST http://127.0.0.1:9495/sql` with `{"sql": "..."}`; it runs the SQL
  untouched and a parse or bind error is a 422 with the message. Or `quack_query('quack:localhost:9494',
  $$...$$, token := getenv('QUACK_TOKEN'))` from a `:memory:` client. Same database either way; never
  open the database file or start another service. Pass the door to subagents.

## Shelf of useful queries

`references/useful_queries.sql` is a shared, append-only file of small verified queries that do not
deserve their own .sql or skill. Read it before writing a query of that kind; when a query of yours
earns its keep, append it with one line saying when to reach for it.

## Explore and compose

- Live SELECTs first; a saved file is an outcome of exploration. Reuse the source CTE and vary the
  later ones; `LIMIT 3` while shaping columns.
- `DESCRIBE` the relation before selecting columns. `agents.ext_catalog` before
  guessing an extension's functions; `INSTALL x FROM community; LOAD x;` the moment one is missing
  (`LOAD` is its own `execute` call before a batch that uses the extension's PRAGMAs or syntax).
- Readers take globs; hostfs for discovery and sizes, shellfs for host commands; measure before
  reading contents.
- A literal/column-parameter binder error means per-row self-dispatch (/duckstack:self-dispatch).
- Project scalars directly (`SELECT 'widget' AS term, * FROM items`); no singleton CTE cross joins.
  `CROSS JOIN UNNEST(arr)` is fine.
- Same-query aliases, named CTEs, `SELECT * EXCLUDE/REPLACE`, `GROUP BY ALL`, `QUALIFY`, `DESCRIBE`,
  `SUMMARIZE`. Counts are a named column (`len(array_agg(id))`), never a star count. No scalar
  subqueries in SELECT lists, no `LIMIT 1` without `ORDER BY` (one row is `arg_max(row, v)`, top n per group
  `arg_max(x, v, n)` / `max(v, n)`), no recursive CTEs, no `AS MATERIALIZED`, no printf. Friendly SQL and the GROUP BY ALL
  pitfall: self-dispatch RULES.md 28-30.
  Prefer CTAS replacement and `INSERT BY NAME`.
- NULL is meaningful: `nullif(col, '')`, never an empty string for a missing value.
- Keep base and intermediate columns; return bounded previews and ids for drill-down.
- Agent conversations: `read_conversations()` directly, see /duckstack:agent-stream.

## Inspect the result

HTTP 200 can carry an error in the body; read the rows, not the status. Never replay an uncertain
write; inspect state first. Keep large receipts as rows rather than one aggregated body.

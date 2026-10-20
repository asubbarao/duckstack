---
name: query
description: >
  Run SQL on dev through its MCP: `query` for a bounded SELECT preview, `query_full` for complete
  results, `execute` for operations. If the MCP is
  missing from the harness, POST the same SQL to dev's /sql or use quack_query. Explore with live
  queries; save a .sql once its shape is proven.
argument-hint: <SQL | question | path.sql>
allowed-tools: mcp__dev__query, mcp__dev__query_full, mcp__dev__execute
---

# Query dev

Read /duckstack:agent-door for the doors and /duckstack:duck for the SQL rules.

- `query(sql)`: one SELECT, including file readers and ShellFS. Returns an object with `rows`,
  `returned_rows`, `truncated`, `reason`, `row_limit: 50` and `byte_limit: 8192`. The complete
  result text fits 8 KiB; 256 bytes are reserved for metadata. Rows are never cut inside a value.
  The first overflow stops the preview; `reason` is `row_limit`, `byte_limit` or `oversized_row`.
  An empty preview with `truncated: true` means data was omitted, not that the query had no rows.
- `query_full(sql)`: runs the posted SQL unchanged and returns all rows without preview limits.
  Use it deliberately when the result size is understood. Service timeout/transport caps still apply.
- `execute(statement)`: one statement of any kind: DDL, DML, COPY, LOAD, ATTACH, SET, file readers,
  shellfs (`read_lines('cmd |')`). One statement per call; a dependent sequence is several calls in
  order.
- Preview preserves the caller's ordering and inner SQL limit; it adds no timestamp ordering.
  Use `ORDER BY` for a meaningful prefix. A SQL limit above 50 still receives a preview; use
  `query_full` for the complete result. A preview limit does not bound aggregate input or memory.
- Use `execute` for `COPY`; the entire source is written. Neither `execute`, `query_full` nor
  HTTP `/sql` has preview limits. Errors remain errors, rather than empty previews.
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
  subqueries in SELECT lists, no `LIMIT 1`, no recursive CTEs, no `AS MATERIALIZED`, no printf.
  Prefer CTAS replacement and `INSERT BY NAME`.
- NULL is meaningful: `nullif(col, '')`, never an empty string for a missing value.
- Keep base and intermediate columns; return bounded previews and ids for drill-down.
- Agent conversations: `read_conversations()` directly, see /duckstack:agent-stream.

## Inspect the result

HTTP 200 can carry an error in the body; read the rows, not the status. Never replay an uncertain
write; inspect state first. Keep large receipts as rows rather than one aggregated body.

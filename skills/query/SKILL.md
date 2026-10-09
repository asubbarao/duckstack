---
name: query
description: >
  Run SQL on dev through its MCP: `query` for a SELECT, `execute` for anything else. If the MCP is
  missing from the harness, POST the same SQL to dev's /sql or use quack_query. Explore with live
  queries; save a .sql once its shape is proven.
argument-hint: <SQL | question | path.sql>
allowed-tools: mcp__dev__query, mcp__dev__execute
---

# Query dev

Read /duckstack:agent-door for the doors and /duckstack:duck for the SQL rules.

- `query(sql)`: a SELECT. No row cap, so write your own `LIMIT` while shaping. It refuses writes and
  file readers.
- `execute(statement)`: one statement of any kind: DDL, DML, COPY, LOAD, ATTACH, SET, file readers,
  shellfs (`read_lines('cmd |')`). One statement per call; a dependent sequence is several calls in
  order.
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
- `DESCRIBE` the relation before selecting columns. `agents.ext_catalog` / `agents.ext_docs` before
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

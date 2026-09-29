---
name: self-dispatch
description: Run SQL that writes SQL and executes it on the same dev DuckDB — per-row table functions (ls, read_csv, read_lines on a path column), crawls, fan-outs, ordered DDL. Use whenever a table function refuses a column argument, when work repeats per row, or when a stage depends on the rows of the one before.
allowed-tools: mcp__dev__query_with_limit, mcp__dev__query_no_limit, mcp__dev__dispatch_sql, mcp__dev__self_dispatch, mcp__dev__dispatch_sequence
---

# Self-dispatch

A table function such as `ls(path)` or `read_csv(path)` takes a literal, not a column. Self-dispatch
gets around it without a loop, a script or a second server: one CTE writes the statement for each
row as text and posts it to this same server's `/sql` route; the next CTE unnests the receipts back
into rows. The database writes the statement it cannot bind, then runs it.

## The molecule: two CTEs

```sql
-- http_post(url VARCHAR, headers MAP(VARCHAR, VARCHAR), body JSON [, params MAP]) -> JSON {status, reason, body}
post AS (
    SELECT array_agg(http_post(
        'http://127.0.0.1:9495/sql',
        MAP {'Content-Type': 'application/json'},
        json_object('sql', printf($$SELECT path FROM ls('%s') LIMIT 100000$$, path))
    )) AS receipts
    FROM previous
    WHERE <the rows worth dispatching>
), result AS (
    SELECT receipt ->> '$.status' AS status, entry.*
    FROM post
    CROSS JOIN UNNEST(receipts) AS r(receipt)
    CROSS JOIN UNNEST(from_json(receipt ->> '$.body', '[{"path":"VARCHAR"}]')) AS e(entry)
)
```

Chain it as often as needed: stage N+1 is written FROM stage N, so the data dependency is the order.

## Worked example: crawl a tree, pruning before descending

`references/declarative_ls.sql` is the whole thing, verified 2026-09-28 on `~/duckdb-skills`
(10 → 64 → 48 paths over three waves, every receipt 200, nothing read under `.git`):

1. `wave1`: `ls(root)` with `is_dir(path)`, `file_name(path)` beside it.
2. `post2`: one `ls('<folder>')` statement per folder that survives
   `NOT starts_with(name, '.') AND name NOT IN ('node_modules', '__pycache__', 'venv')`.
3. `wave2`: the receipts unnested. Repeat 2–3 for each further level.

The filter sits **before** the dispatch, so a pruned folder is never listed. Filtering the output of
`lsr(root)` is the opposite: it walks all of `.venv` first. The server can run the file itself:
`SELECT http_post(…, json_object('sql', 'SELECT … FROM (' || content || ') …')) FROM read_text('<file>')`.

## Traps (measured)

- `/sql` caps an unlimited SELECT at **20 rows**, silently. Every dispatched SELECT gets its own
  outer `LIMIT`, or returns `array_agg` of its rows as one value.
- The receipt body is a JSON array inside a string: `from_json(receipt ->> '$.body', '[{…}]')`.
- A failed statement is a receipt with a non-200 status and the error in its body; keep it as a row.
- Large bodies: don't `array_agg` tens of MB of receipts; post one row each instead.
- Dependent DDL (create → alter → insert) goes in one ordered body (`dispatch_sequence`), not as
  parallel rows, which can run out of order.
- A path containing `'` breaks the `printf` quoting; double it with `replace(path, chr(39), chr(39) || chr(39))`.

Never: `SET VARIABLE` as orchestration, `WITH RECURSIVE`, `AS MATERIALIZED`, `LEFT JOIN LATERAL
UNNEST`, a second server, or a shell loop around DuckDB. If dev itself misbehaves, restart it
(the `light-switch` skill) rather than working around it.

---
name: self-dispatch
description: Run SQL that writes SQL and runs it on the same dev DuckDB. Use when a table function refuses a column argument (ls, read_csv, read_lines, crawl on a path column), when work repeats per row, or when a stage depends on the rows of the one before.
---

# Self-dispatch

A table function such as `ls(path)` takes a literal, not a column. Self-dispatch gets around it
without a loop, a script or a second server: SQL writes the statement for each row, and dev runs it.

## The molecule

One `ls` per surviving folder per level, pruned by name before the next level is written. Never
`lsr` on an unpruned folder: `lsr(child, 1)` lists the inside of `.venv` and `.pytest_cache` before
any WHERE runs (measured 2026-10-09).

```sql
WITH folders AS (
    SELECT path FROM ls('/Users/aloksubbarao/duckdb-skills/skills')
    WHERE is_dir(path) AND NOT starts_with(file_name(path), '.')
), posted AS (
    SELECT path AS folder,
           from_json(http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'},
                               json_object('sql', $$SELECT path FROM ls('$$ || path || $$')$$)),
                     '{"status": "INTEGER", "body": "VARCHAR"}') AS receipt
    FROM folders
), listed AS (
    SELECT folder, receipt.status, from_json(receipt.body, '[{"path": "VARCHAR"}]') AS entries FROM posted
)
SELECT folder, status, entry.path
FROM listed CROSS JOIN UNNEST(entries) AS e(entry);
```

`http_post` returns JSON; `from_json` with the shape you expect turns it into a struct, so the
receipt is `receipt.status` and `receipt.body`, and the body (itself a JSON string) becomes rows
the same way. Verified on dev 2026-10-09: 36 folders → 36 receipts, all 200, 55 paths. Chain it:
stage N+1 is written FROM stage N, so the data dependency is the order. The filter sits before the
dispatch, so a pruned folder is never listed.

## Rules

- The statement is a dollar-quoted literal with the value concatenated in, as above. No printf and
  no hand-built quoting.
- `/sql` runs the statement untouched and returns its rows; a parse or bind error is a 422 receipt
  with the message in `receipt.body`. Keep failed receipts as rows.
- A single statement an agent wants run goes through the dev MCP `execute` tool, not through this.
- Dependent DDL (create → alter → insert) is one ordered body, not parallel rows.
- Large results: post one row each and tabulate `status`, instead of `array_agg` of tens of MB.
- No session variables as orchestration, no recursive CTEs, no second server, no shell loop around
  DuckDB. If dev misbehaves, restart it (`light-switch`) rather than working around it.

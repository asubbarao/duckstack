---
name: self-dispatch
description: Run something once per row (a command, a file read, a SQL statement, an HTTP request) from one query. Concat each row's executable statement into a column, SELECT the row's columns with array_agg(selfdispatch(sql)) GROUP BY ALL, then CROSS JOIN UNNEST, so each receipt sits beside its row. Use for any per-row command, file, statement or request, any binder error about literal arguments, and instead of loops, scripts, lateral joins or parallel arrays.
---

# Self-dispatch

Concat each row's statement into a string, post it to yourself, and unnest. The row keeps its own columns:

```sql
WITH folders AS (
    SELECT name AS folder_name, path FROM fs.folders WHERE parent = concat(getenv('HOME'), '/.duck')
), dispatched AS (
    SELECT folder_name,
           array_agg(selfdispatch(concat('SELECT * FROM read_csv(', quote_literal(concat('ls -la ', path, ' |')), ', header := false)'))) AS receipts
    FROM folders GROUP BY ALL
)
SELECT folder_name, receipt.status, receipt.error, receipt.body
FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);
```

Verified on dev 2026-10-18: every folder's `ls -la` came back with status 200, each receipt beside its own `folder_name`.

That is the whole pattern:
- **The statement is a concat.** A file reads as `read_csv(` + the path + `)`. A command reads as `read_csv(` + the
  command + ` |` + `)`. A SQL statement is the text of that statement. `quote_literal` wraps a value in quotes.
- **The row keeps its columns.** Select the row's key columns next to `array_agg(selfdispatch(sql))`, add
  `GROUP BY ALL`, then `CROSS JOIN UNNEST(receipts)`. Every receipt comes back beside its row. Never two arrays
  matched by position (`receipts[n]`); the hook blocks that.
- **Check status.** A failed statement comes back as 422 or 500 with DuckDB's error message in the body. Flag it with
  `receipt.status IS DISTINCT FROM 200` and keep the row.
- **The next stage** builds its statements from these rows (`folder_name`, `receipt.body`): the same two CTEs again.
  Order comes from that dependency.

## Templates, when the statement has many holes

When a concat grows past a line, render it with a template by name instead. `templates/canonical.sql` has a verified
example of each.

| template | for | row columns |
|---|---|---|
| `sql.tera` | a SQL statement in the database | table_schema, table_name, … |
| `shell.tera` | commands or files through `read_csv`, `read_json`, `read_text`, `read_blob` | reader, sources, options |
| `network.tera` | one request per row to another host, including another DuckDB's `:9495/sql` | url, body |
| `bash_loop_fallback_method.tera` | FALLBACK: a shell loop when no row source exists | items, body |

Nesting is fine: build the per-row statements, `array_agg` them, and send that array through `network.tera` to
another host's `:9495`, which self-dispatches it there. Git data comes from dev's duck_tails views (`git_changes`,
`branch_diff`, `git_worktrees`), joined.

Dev is `http://127.0.0.1:9495/sql`, reached through the `selfdispatch(sql)` macro. Empty input sends nothing. Alok's
full rules: [RULES.md](RULES.md).

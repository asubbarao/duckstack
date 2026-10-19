---
name: self-dispatch
description: Run something once per row (a command, a file read, a SQL statement, an HTTP request) from one query. Rows → one generated statement per row (tera_render with a canonical template) → array_agg of the row with selfdispatch(sql) → CROSS JOIN UNNEST, each receipt beside its row's columns. Use for any per-row command/file/statement/request, any binder error about literal arguments, and instead of loops, scripts, lateral joins or parallel arrays. Four templates: sql, shell, network, bash_loop_fallback_method.
---

# Self-dispatch

Every self-dispatch is three CTEs. The row's own columns travel with its receipt:

```sql
WITH folders AS (                    -- 1. the rows, with every value the statement needs as a column
    SELECT name AS folder_name, 'read_csv' AS reader, ', header := false' AS options,
           [concat_ws(' ', 'ls', path, '|')] AS sources
    FROM fs.folders WHERE parent = concat(getenv('HOME'), '/.duck')
), rendered AS (                     -- 2. one statement per row, from a canonical template by name
    SELECT folder_name, tera_render('shell.tera', c::JSON, autoescape := false,
                       template_path := concat_ws('/', getenv('HOME'), '.duck/deploy/skills/self-dispatch/templates/*.tera')) AS sql
    FROM folders AS c
), dispatched AS (                   -- 3. post every statement; aggregate each row WITH its receipt
    SELECT array_agg({'folder_name': folder_name, 'receipt': selfdispatch(sql)}) AS dispatched FROM rendered
)
SELECT d.folder_name, d.receipt.status, d.receipt.error, d.receipt.body
FROM dispatched CROSS JOIN UNNEST(dispatched) AS t(d);
```

Verified on dev 2026-10-18: 46 folders, each receipt next to its own `folder_name`, all status 200.

- **The row rides with its receipt.** Put the key columns (and anything the next stage needs) in the struct next to
  `selfdispatch(sql)`. Never aggregate rows and receipts as two arrays and match them with `receipts[n]`; the hook
  blocks that (`sql_dispatch_positional`).
- **Check status.** A failed statement comes back with status 422 or 500 and DuckDB's error message in the body.
  Flag it with `d.receipt.status IS DISTINCT FROM 200` and keep the row.
- **The next stage** renders from this stage's unnested rows (`d.folder_name`, `d.receipt.body`): two more CTEs,
  the same shape. Order comes from that dependency, not from sleeps or positions.

## Templates, called by name

`templates/canonical.sql` has a verified example of each.

| template | for | row columns |
|---|---|---|
| `sql.tera` | a SQL statement in the database: SELECT, DDL, DML, PRAGMA | table_schema, table_name, … |
| `shell.tera` | commands or files through `read_csv`, `read_json`, `read_text`, `read_blob`; curl, gh, git, osascript are commands | reader, sources (a command ends with ` \|`, a file is its path), options |
| `network.tera` | one request per row to another host, including another DuckDB's `:9495/sql` | url, body |
| `bash_loop_fallback_method.tera` | FALLBACK: a shell loop when no row source exists | items, body |

Nesting is allowed when it helps: render the per-row statements, `array_agg` them, and send that array through
`network.tera` to another host's `:9495`, which self-dispatches it there. Git data comes from dev's duck_tails
views (`git_changes`, `branch_diff`, `git_worktrees`), joined; no template needed.

## Rules

- **Declare first.** Every value the statement needs is a column of the first CTE. Command words split by role
  (program, arguments, flags) and joined with same-query aliases: `list_concat(gh_pr_list, repo_args, list_flags)`.
- **Tera fills holes.** No `{% if %}`, no logic in templates.
- **The dispatch is visible**: `array_agg({..., 'receipt': selfdispatch(sql)})` then `CROSS JOIN UNNEST`.
- Dev is `http://127.0.0.1:9495/sql`, reached only through the `selfdispatch(sql)` macro. Empty input sends nothing.
  Never blindly retry an uncertain write.

Alok's full rules: [RULES.md](RULES.md). Background: [compendium](references/compendium.md).

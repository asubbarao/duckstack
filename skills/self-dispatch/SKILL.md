---
name: self-dispatch
description: Run something once per row (a command, a file read, a SQL statement, an HTTP request) from one query. Build each row's executable statement in its own column, SELECT the row's columns and that statement with array_agg(selfdispatch(sql)) GROUP BY ALL, then CROSS JOIN UNNEST, so each receipt sits beside its row. Templates in templates/ (sql, shell, pipeline, network, bash_loop_fallback_method) for statements with many holes. Use for any per-row command, file, statement or request, any binder error about literal arguments, and instead of loops, scripts, lateral joins or parallel arrays.
---

# Self-dispatch

Build each row's statement in a column, post it to yourself, and unnest. The row keeps its own columns, and the
statement sits beside them, so you can select `statements` and read every program before anything is posted:

```sql
WITH folders AS (
    SELECT name AS folder_name, path FROM fs.folders WHERE parent = concat(getenv('HOME'), '/.duck')
), statements AS (
    SELECT folder_name, concat('SELECT * FROM ls(', quote_literal(path), ')') AS sql FROM folders
), dispatched AS (
    SELECT folder_name, sql, array_agg(selfdispatch(sql)) AS receipts FROM statements GROUP BY ALL
)
SELECT folder_name, sql, receipt.status, receipt.error, receipt.body, receipt.status IS DISTINCT FROM 200 AS failed
FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);
```

Verified on dev 2026-10-20 (46 rows, first two; body cut):

| folder_name | sql | status | error | body | failed |
|---|---|---|---|---|---|
| agent_log | `SELECT * FROM ls('…/.duck/agent_log')` | 200 | NULL | `[{"path":"…/.duck/agent_log/skill_trial_2026_10_17"}, …]` | false |
| agent_stream | `SELECT * FROM ls('…/.duck/agent_stream')` | 200 | NULL | `[{"path":"…/.duck/agent_stream/launchd-retired"}, …]` | false |

hostfs `ls()` takes only a literal path, so this is the case self-dispatch exists for. With `SELECT name, size …`
in place of `*`, every row came back as status 422 with DuckDB's binder error in `receipt.error`: a failure is a
row, not a crash.

That is the whole pattern:
- **The statement is a column.** A file reads as `read_csv(` + the quoted path + `)`. A command with no extension
  for it reads as `read_csv(` + the quoted command ending in ` |` + `)`. A SQL statement is its text.
  `quote_literal` wraps a value in quotes. Build it in its own CTE (`statements`, column `sql`), never inside
  `selfdispatch(...)`, so the programs can be inspected before they are posted.
- **The row keeps its columns.** Select the row's key columns and `sql` next to `array_agg(selfdispatch(sql))`,
  add `GROUP BY ALL`, then `CROSS JOIN UNNEST(receipts)`. Every receipt comes back beside its row and its statement.
  Never two arrays matched by position (`receipts[n]`); the hook blocks that.
- **Check status.** A failed statement comes back as a non-200 status with DuckDB's error in `receipt.error` and the
  full `{"detail": …}` in the body: 422 for binder, parser, cast and missing-file errors alike (verified on dev
  2026-10-20). Flag it with `receipt.status IS DISTINCT FROM 200` and keep the row.
- **The next stage** builds its statements from these rows (`folder_name`, `receipt.body`): the same three CTEs
  again. Order comes from that dependency.

## Templates, when the statement has many holes

When a concat grows past a line, render it with a template by name instead, still into the `sql` column.
`templates/canonical.sql` has a verified example of each.

| template | for | row columns |
|---|---|---|
| `sql.tera` | in the database: SELECT, DDL, DML, PRAGMA, names from information_schema | table_schema, table_name, … |
| `shell.tera` | commands or files through `read_csv`, `read_json`, `read_text` or `read_blob`; many sources per statement; curl, gh, osascript and git are commands | reader, sources (list: a command ends with ` \|`, a file is its path), options. jq is a boolean in the first CTE that appends only `\| jq -c '.[]'` |
| `pipeline.tera` | one command or pipeline written as words, so no `concat_ws` builds the line; `'\|'` is a word, and a flag with its value may be one word (`'--max-time 30'`) | reader, words (list), options |
| `network.tera` | one request per row to another host (never dev's own `:9495`); status, reason, body come back as columns | url, body |
| `bash_loop_fallback_method.tera` | FALLBACK: a bash loop when no row source exists; the audit lists every use | items, body |

**Words for `pipeline.tera`:** a list, with a flag and its value as one word and `'|'` as the pipe:

```sql
['curl', '-sS', '--max-time 30'] AS curl_base,
list_concat(curl_base, ['-c -', '-o /dev/null', quote_literal(login_url)]) AS log_in,
list_concat(curl_base, ['--fail', '-b -', quote_literal(page_url)]) AS get_page,
list_concat(log_in, ['|'], get_page) AS log_in_then_get_page
```

Nesting is fine: build the per-row statements, `array_agg` them, and send that array through `network.tera` to
another host's `:9495`, which self-dispatches it there. Git data comes from dev's duck_tails views (`git_changes`,
`branch_diff`, `git_worktrees`), joined.

Dependent stages in one query (each stage an atom that dispatches and a molecule that unnests; the next atom renders
from the last molecule's rows): [references/five_stage_pipeline.sql](references/five_stage_pipeline.sql).

Dev is `http://127.0.0.1:9495/sql`, reached through the `selfdispatch(sql)` macro. Empty input sends nothing. Alok's
full rules: [RULES.md](RULES.md).

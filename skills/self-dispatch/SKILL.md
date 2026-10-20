---
name: self-dispatch
description: Generate readable SQL from rows, execute native JSON self-posts, and unnest receipts. Three templates in templates/: shell (any reader, batch sources, jq on/off), sql, and bash_loop_fallback_method.
---

# Self-dispatch

An **atom is a control relation**: the original source columns plus a readable `executable_sql`
column. Selecting it shows the programs without executing them. This is the ordinary control-table
pattern; the generated program may use SQL, a ShellFS command reader or a network request.
The caller owns every filter, argument and decision. Tera only substitutes those columns.

Keep the source columns and executable SQL when collecting `array_agg(selfdispatch(executable_sql)) AS arr`.
The molecule exposes its results with `CROSS JOIN UNNEST(arr)`, beside the source row. Further atoms
read those results, so the whole dependency graph can stay one query. No encoding is needed.
Preparation can take several CTEs; a fixed CTE count is not the contract.

One small example:

```sql
WITH table_statements AS (
    SELECT table_schema, table_name,
           concat('SELECT * FROM information_schema.columns WHERE table_schema = ',
                  quote_literal(table_schema), ' AND table_name = ', quote_literal(table_name)) AS executable_sql
    FROM information_schema.tables WHERE table_catalog = current_database()
), table_posts AS (
    SELECT *, array_agg(selfdispatch(executable_sql)) AS arr FROM table_statements GROUP BY ALL
)
SELECT source.* EXCLUDE(arr), receipt.* FROM table_posts AS source CROSS JOIN UNNEST(arr) AS t(receipt);
```

Pick the template by what the statement does. `templates/canonical.sql` has a verified example of each.

| template | for | row columns |
|---|---|---|
| `shell.tera` | commands or files through `read_csv`, `read_json`, `read_text` or `read_blob`; many sources per statement; curl, gh, osascript and git are commands | reader, sources (list: a command ends with ` \|`, a file is its path), options. jq is a boolean in the first CTE that appends only `\| jq -c '.[]'` |
| `sql.tera` | in the database: SELECT, DDL, DML, PRAGMA, names from information_schema | table_schema, table_name, … |
| `bash_loop_fallback_method.tera` | FALLBACK: a bash loop when no row source exists; the audit lists every use | items, body |

Dependent stages in one query (each stage an atom that dispatches and a molecule that unnests; the next atom renders
from the last molecule's rows): [references/five_stage_pipeline.sql](references/five_stage_pipeline.sql).

Rules:

- **Declare first.** Everything the statement needs is a column of the first CTE. No `json_object(...)` built
  inside later CTEs, no nested renders, no list arguments to a macro.
- **Tera fills holes.** The template is the finished statement with `{{ holes }}`; no `{% if %}`, no logic,
  no `extends`. `join(sep=" ")` on a declared list is fine.
- **The dispatch is visible:** `array_agg(selfdispatch(sql))` then `CROSS JOIN UNNEST`. Never hide
  `selfdispatch` inside a macro.
- **Order:** an array of posts has no order. Steps that depend on each other go in one statement, or in the
  next CTE's dispatch built from this one's receipts.
- Dev is `http://127.0.0.1:9495/sql`; `selfdispatch(sql)` wraps `quackapi_post`. Empty input sends nothing.
  Never blindly retry an uncertain write.

Background: [compendium](references/compendium.md), [inline.sql](references/inline.sql),
[review.sql](references/review.sql) (every dispatch site, for the `duckstack-review` checks).

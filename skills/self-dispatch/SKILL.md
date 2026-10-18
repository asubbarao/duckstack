---
name: self-dispatch
description: Generate readable SQL from rows, execute native JSON self-posts, and unnest receipts. Five canonical templates (shell, pipeline, sql, network, loop) in templates/.
---

# Self-dispatch

Every self-dispatch is the same three CTEs:

```sql
WITH c AS (                         -- 1. declare everything up front: rows, the command as text,
    SELECT ...                      --    options as text, values prequoted (quote_literal)
), rendered AS (                    -- 2. one statement per row; Tera only fills holes
    SELECT tera_render('shell.tera', c::JSON, autoescape := false,
                       template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS sql
    FROM c
), dispatched AS (                  -- 3. post them; the receipts come back as rows
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);
```

Pick the template by what the statement does. `templates/canonical.sql` has a verified example of each.

| template | for | row columns |
|---|---|---|
| `shell.tera` | one shell command (files, processes, osascript, git, gh) | reader, command, options |
| `jq_array_to_lines.tera` | only when read_json cannot read the output whole (e.g. `gh api --paginate`): jq splits one array into lines, nothing more | command, array |
| `sql.tera` | in the database: SELECT, DDL, DML, PRAGMA, names from information_schema | table_schema, table_name, … |
| `network.tera` | another host: curl through shellfs (or `quackapi_post` to another service) | reader, url, options |
| `bash_loop_fallback_method.tera` | FALLBACK: a bash loop when no row source exists; the audit lists every use | items, body |

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

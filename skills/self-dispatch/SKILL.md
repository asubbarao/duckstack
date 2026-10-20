---
name: self-dispatch
description: Generate readable SQL from rows, execute native JSON self-posts, and unnest receipts. Four templates in templates/: shell (any reader, batch sources, jq on/off), pipeline (one command as words), sql, and bash_loop_fallback_method.
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
| `shell.tera` | commands or files through `read_csv`, `read_json`, `read_text` or `read_blob`; many sources per statement; curl, gh, osascript and git are commands | reader, sources (list: a command ends with ` \|`, a file is its path), options. jq is a boolean in the first CTE that appends only `\| jq -c '.[]'` |
| `pipeline.tera` | one command or pipeline written as words, so no `concat_ws` builds the line; `'\|'` is a word, and a flag with its value may be one word (`'--max-time 30'`) | reader, words (list), options |
| `sql.tera` | in the database: SELECT, DDL, DML, PRAGMA, names from information_schema | table_schema, table_name, … |
| `bash_loop_fallback_method.tera` | FALLBACK: a bash loop when no row source exists; the audit lists every use | items, body |

**Words for `pipeline.tera`.** Any of these is fine; pick the one that reads best. Observed on dev 2026-10-20:
- A word list, a flag with its value as one word: `['curl', '-sS', '--max-time 30', '-c -', quote_literal(url)]`.
  The default; always allowed. A shared prefix is one column reused with `list_concat(curl_base, [...])`.
- Groups then `flatten([['curl', '-sS'], ['--max-time', '30']])`: allowed, same result, adds nothing.
- Flags as a MAP, when flags come from rows or a base gets overrides: `map(list(flag), list(flag_value))` per site,
  `map_concat(base, overrides)` (a later key replaces the earlier value in its place), then words with
  `flatten(list_transform(map_entries(flags), e -> list_filter([e.key, e.value], w -> w IS NOT NULL)))`. A flag with
  no value is `NULL::VARCHAR` (a bare `NULL` makes the map `MAP(VARCHAR, "NULL")`, which `map_concat` refuses).
  Keys are unique, so a repeated flag (`-H` twice) stays in a word list.
- Flags as a STRUCT: typed values (`"--max-time" INTEGER`) and `struct_update`, but not for flags that differ by row:
  a list of structs merges every row's fields, so a missing flag and a flag with no value are both NULL.

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

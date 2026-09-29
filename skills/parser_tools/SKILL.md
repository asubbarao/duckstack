---
name: parser_tools
description: >
  Validate SQL and inspect its parsed tables, functions, statements, and WHERE conditions
  with DuckDB's native parser. Reach for this when SQL text or extracted code blocks must be
  structurally classified without regex, keyword matching, or executing the SQL.
---

# Parser tools

Read `/duckstack:duck` first. The selected dev server has `parser_tools` available. Keep this
as analysis of SQL text: `SELECT`s only, no execution of the parsed statements, no `regexp_*`,
and no keyword `LIKE` scan pretending to be a parser.

## Verified function surface

Verified against dev through `quack_query` on 2026-09-19 with:

```sql
SELECT function_name, function_type, parameters, parameter_types, varargs
FROM duckdb_functions()
WHERE function_name IN (
  'is_parsable', 'num_statements', 'parse_function_names', 'parse_functions',
  'parse_statements', 'parse_table_names', 'parse_tables', 'parse_where',
  'parse_where_detailed'
)
ORDER BY function_name, function_type, parameter_types::VARCHAR;
```

Every registered argument is positional. `col0` and `col1` are the real parameter names from
`duckdb_functions()`, not documentation aliases.

| Function | Kind | Parameters reported by `duckdb_functions()` |
|---|---|---|
| `is_parsable` | scalar | `col0 VARCHAR` |
| `num_statements` | scalar | `col0 VARCHAR` |
| `parse_function_names` | scalar | `col0 VARCHAR` |
| `parse_functions` | scalar | `col0 VARCHAR` |
| `parse_functions` | table | `col0 VARCHAR` |
| `parse_statements` | scalar | `col0 VARCHAR` |
| `parse_statements` | table | `col0 VARCHAR` |
| `parse_table_names` | scalar | `col0 VARCHAR`[, `col1 BOOLEAN`] |
| `parse_tables` | scalar | `col0 VARCHAR` |
| `parse_tables` | table | `col0 VARCHAR` |
| `parse_where` | scalar | `col0 VARCHAR` |
| `parse_where` | table | `col0 VARCHAR` |
| `parse_where_detailed` | table | `col0 VARCHAR` |

Call position chooses the overload: `SELECT parse_tables(sql)` returns a list-valued scalar;
`FROM parse_tables('<literal>')` returns one row per reference. The same distinction applies to
`parse_functions`, `parse_statements`, and `parse_where`.

## Generated SQL — validate before dispatch or execution

Use this as a general gate for Tera output, generated migration candidates, or
SQL extracted from an HTML code block. Keep the generated string beside the
parser facts. `is_parsable` is cheap and scalar, so it works directly over a
relation of generated programs:

```sql
WITH generated AS (
    SELECT 'crawler-page-reader' AS program_name, generated_sql
    FROM rendered_templates
)
SELECT
    program_name,
    is_parsable(generated_sql) AS parsable,
    num_statements(generated_sql) AS statement_count,
    parse_function_names(generated_sql) AS function_names,
    left(generated_sql, 100) AS preview
FROM generated;
```

Only execute or self-dispatch a program after the parser gate is true and its
statement/function facts match intent. This checks grammar; it does not prove
extension loading, object existence, permissions, or runtime success.

## Worked example — validate, then inspect

All three statements below were run through `quack_query`.

```sql
WITH code_blocks AS (
    SELECT 'valid' AS label, 'SELECT upper(u.name) FROM users u JOIN teams t ON u.team_id = t.id' AS sql
    UNION ALL
    SELECT 'invalid', 'SELECT FROM'
)
-- is_parsable(col0 VARCHAR): no optional parameters or defaults.
SELECT label, is_parsable(sql) AS valid
FROM code_blocks
ORDER BY label DESC;
```

```text
label    valid
valid    true
invalid  false
```

For the valid SQL:

```sql
-- parse_tables(col0 VARCHAR): no optional parameters or defaults.
FROM parse_tables(
  'SELECT upper(u.name) FROM users u JOIN teams t ON u.team_id = t.id'
);
```

```text
schema  table  context
main    users  from
main    teams  join_right
```

```sql
-- parse_functions(col0 VARCHAR): no optional parameters or defaults.
FROM parse_functions(
  'SELECT upper(u.name) FROM users u JOIN teams t ON u.team_id = t.id'
);
```

```text
function_name  schema  context
upper          main    select
```

The starting claims are correct: `is_parsable(text)` distinguishes the two SQL bodies, and
`parse_tables` plus `parse_functions` are both scalar and table functions.

## Gotchas verified while writing this skill

- The table forms are literal-bound. This failed:

  ```sql
  WITH q(sql) AS (VALUES ('SELECT upper(name) FROM users'))
  SELECT * FROM q CROSS JOIN LATERAL parse_functions(sql);
  ```

  Exact error: `Table function "parse_functions" does not support lateral join column
  parameters ... The function only supports literals as parameters.` Use the scalar form over
  a SQL-text column, then `UNNEST`, or use `/duckstack:self-dispatch` when table-form output is
  required per row.
- `is_parsable` answers syntax, not bindability, permissions, or whether referenced tables and
  functions exist. It is a parser gate, not an execution guarantee.
- Parse the text inside a fenced code block, not the backticks and language tag. Preserve the
  original block beside the parsed result as evidence.

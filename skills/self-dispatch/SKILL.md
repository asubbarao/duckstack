---
name: self-dispatch
description: Generate readable SQL from rows, execute native JSON self-posts, and unnest receipts.
---

# Self-dispatch

SQL builds an `sql` column; execution posts it to the selected service, collects the
receipts with `array_agg`, then `CROSS JOIN UNNEST` exposes them as rows.

Read the [compendium](references/compendium.md) for the construction and execution
cases, actual-use inventory, named templates, quoting, inserts and failure handling.
[inline.sql](references/inline.sql) contains runnable SQL-only, file-reader,
command/CSV and repeated-pipeline/JSON examples.

Use Tera to make the generated program look like ordinary SQL:
`tera_render(template, c::JSON, autoescape := false)`. SQL owns selection, joins,
filtering and values. Tera supplies substitutions and repeated syntax. Prefer a
short inline template; use a named SQL template when sharing it improves readability.
Someone should be able to replace Tera with plain SQL string construction without
redesigning the program. This is a design goal, not a second implementation to maintain.

Prequoted columns such as `lit` are fine. `quote_literal(col)` wraps a value in single quotes;
do not add a generic dispatch framework. No new macro without the user's approval.
A reader that supports native correlation can be called directly. A literal-binding
error in an ordinary table function calls for rendering and posting one statement per row.

Dev here is `http://127.0.0.1:9495/sql`; send each statement with `selfdispatch(sql)`,
which wraps `quackapi_post` with `url_build` and `:=` overrides (`port`, `hostname`,
`pathname`, `headers`). Do not discover and cross join listeners or
create another server. Preserve the generated SQL, source identity and full receipts
when they are needed downstream. Empty input sends nothing. Arrays do not establish
execution order; dependent writes belong in one ordered body. Never blindly retry
an uncertain write.

Historical transport measurements are in the [compendium](references/compendium.md#historical-transport-measurements).

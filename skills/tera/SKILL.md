---
name: tera
description: Render inline or named Tera templates through the selected DuckDB MCP. Use for repeated text structure, template includes, or generated SQL and shell programs; not to wrap simple commands.
argument-hint: "[template path or render error]"
allowed-tools: mcp__dev__render, mcp__dev__query_with_limit, mcp__dev__query_no_limit, mcp__dev__self_dispatch
---

# Tera

Use the selected DuckDB MCP. `render(template, ctx)` takes a template file path
and a JSON-object string. SQL can call the same native `tera_render` function.

Templates own repeated syntax, not business logic. SQL selects, filters, joins
and prepares the context. Prefer a plain `ls -la|` or scalar HTTP call when that
is clearer. Self-dispatch does not require Tera, a macro, or a dedicated tool.

## Native calls

```sql
INSTALL tera FROM community;
LOAD tera;

-- template VARCHAR: inline body, or name when template_path is supplied.
-- context JSON: object; pass '{}' explicitly when there are no variables.
-- autoescape BOOLEAN := true; false for SQL, shell and other non-HTML text.
-- template_path VARCHAR: optional glob; absent means an inline template.
SELECT tera_render(
    'reader.tera',
    json_object('reader', 'read_lines', 'interpreter', '/bin/bash -o pipefail',
                'script', 'printf hello', 'heredoc', 'END_EXAMPLE',
                'sql_tag', 'pipe', 'row_limit', 1000),
    autoescape := false,
    template_path := '/explicit/templates/*.tera'
);
```

Named file loading and nested `{% include "command.tera" %}` work on the
installed build (verified 2026-09-28). Inline rendering alone does not load
sibling files. A missing-template error means check the glob and template name,
not that the extension lacks a file loader.

Reusable examples live in `~/duckdb-dataswarm/duckdb/templates/`:

- `call.tera`: one selector for Bash flags or table-function named parameters.
  Context: `kind` (bash/table), `name`, positional `args`, and ordered
  `options` rows with `name`/`value`. Values are authored language fragments,
  not an escaping API for untrusted data. Table calls require a positional arg.
  Tested SQL and visible generated statements: `duckdb/examples/calls.sql`.
- `command.tera`: run an explicit interpreter with a quoted heredoc.
- `reader.tera`: include that command inside a native reader's dollar-quoted pipe.
- `lines.tera`: repeat supplied lines; ordinary string aggregation is often enough.

Use distinct dollar-quote and heredoc delimiters absent from the supplied script.
The MCP shell tool generates UUID-based delimiters. A quoted heredoc prevents
the outer shell from expanding the script; the chosen interpreter still executes
it. Templates and executable scripts are trusted code, not an injection boundary.
For external values, use real parameter binding or native encoding appropriate
to the target language. HTML escaping is neither SQL nor shell quoting.

## Plain loop

```sql
SELECT tera_render(
    $tpl${% for line in lines %}{{ line }}
{% endfor %}$tpl$,
    json_object('lines', ['first', 'second']),
    autoescape := false
);
```

Keep the context as data (`json_object`, structs, lists); do not hand-escape JSON.
No new SQL or Tera macros. Include small named templates when actual repetition
justifies them. Do not add Bash loops to replace relational SQL.

## Nested templates: a runner and a loop (shellfs self-dispatch, verified 2026-09-28)

A shellfs call has three parts: the reader around it (`read_csv('… |', …)`), the command with its own flags,
and the reader's `:=` options. A tera `macro` is the runner for one command; a `for` loop calls it once per row,
each with its own flags and options; the rendered statement is self-dispatched to `/sql`.

```sql
-- tera_render(template VARCHAR [, context JSON]) -> VARCHAR   (autoescapes: ' becomes &#x27;)
-- html_unescape(VARCHAR) -> VARCHAR                          (webbed; undoes it — never replace() entities by hand)
-- http_post(url VARCHAR, headers MAP, body JSON [, params MAP]) -> JSON {status, reason, body}
WITH commands AS (
    SELECT 'ls' AS cmd, '-1 /Users/aloksubbarao/duckdb-skills/server' AS flags, 'header := false, delim := ' || chr(39) || '|' || chr(39) || ', names := [' || chr(39) || 'line' || chr(39) || ']' AS opts
    UNION ALL SELECT 'date', '-u', 'header := false, delim := ' || chr(39) || '|' || chr(39) || ', names := [' || chr(39) || 'line' || chr(39) || ']'
), program AS (
    SELECT html_unescape(tera_render($t${% macro run(cmd, flags, opts) %}SELECT '{{ cmd }}' AS cmd, * FROM read_csv('{{ cmd }} {{ flags }} |', {{ opts }}){% endmacro run %}{% for c in commands %}{{ self::run(cmd=c.cmd, flags=c.flags, opts=c.opts) }}{% if not loop.last %} UNION ALL BY NAME {% endif %}{% endfor %} LIMIT 100000$t$,
        json_object('commands', array_agg({'cmd': cmd, 'flags': flags, 'opts': opts})))) AS statement
    FROM commands
)
SELECT statement, http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', statement)) ->> '$.body' AS rows
FROM program
```

- Encoding is a function, never a hand fix: `html_unescape` / `html_escape` (webbed), `url_encode` / `url_decode`
  (core), `base64_*`. The template sits in `$t$…$t$` so its single quotes need no doubling; `:=` values are
  built with `||` and `chr(39)` in the rows.
- Pass `read_csv`'s `delim` explicitly: `uname -a` contains `:`, the sniffer split on it and produced a `column1`.
- Same shape for osascript (Chrome bridge / conduit: one runner per window or tab, looped), curl, gh: the runner
  is the command's grammar, the rows are the calls.

## Measured limits and diagnostics

- `date` and `urlencode` filters are absent in this build (retested 2026-09-28).
  Use native SQL formatting and URL functions. Documentation for the full Rust
  engine is not proof that every filter is compiled into this extension.
- Missing variables fail; JSON null renders empty. Use `default(value=...)`
  only when missing data is genuinely acceptable.
- Use the two-argument overload even for empty context: the one-argument overload
  was observed to ignore `autoescape := false`.
- Tera's `//` and arithmetic involving parenthesized filters were unsupported
  in local tests. Compute those values in SQL.
- The installed function is marked side-effecting. If DuckDB refuses reuse of
  its alias in the same projection, consume it in the next CTE.
- A parse error identifies template syntax and a line/column; a render error
  identifies missing context, filters or templates. Inspect the inner cause.
- Preserve generated SQL and raw dispatch receipts. A render result is not proof
  that its SQL or command executed. No automatic retry after an uncertain write.

`read_csv`/`read_json` are the primary structured readers; `read_lines` retains
line and byte-offset metadata. `read_text`/`read_blob` read whole objects.
Do not invent a single VARCHAR column to flatten structured stdout. Prefer native
schema detection; CSV `all_varchar := true` keeps detected column names. JSON
`columns` can discard unspecified fields. Read raw text through `read_lines`.
The installed read_lines has line selectors, not fixed-width column parsing;
derive fixed-width fields afterwards while retaining content and offsets.
Never detect formats by rerunning a command with different readers after failure.
A streaming LIMIT can terminate an upstream command: a preview does not certify
all side effects completed.

Sources: [extension and cookbook](https://query.farm/products/extensions/tera/),
[function reference](https://query.farm/products/extensions/tera/functions/category/render/).

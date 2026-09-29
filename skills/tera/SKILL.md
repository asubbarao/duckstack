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

For ShellFS readers, use the two nested templates in `references/`:

- `bash_pipeline.tera` renders `stages = [{command, args, flags}]`, preserving stage and flag order.
- `shell_reader.tera` includes that pipeline directly in a ShellFS path, then renders
  `reader = {name, parameters}` as `read_x($pipe$...|$pipe$, name := value, ...)`.
- `shell_readers.sql` is the runnable JSON/CSV/lines example and the current `read_csv`/`read_json`
  parameter and encoding reference. Read it before adding reader-specific flags.

SQL chooses the stages, reader and parameters; the templates contain no business rules. Use
`read_json` and `read_csv` directly: both already auto-detect. Prefer them for structured stdout.
Use `read_lines` when line and byte offsets are the structure. `read_text` reads whole objects in a
batch and is not a streaming fallback. Use `read_blob` to preserve bytes after text decoding fails;
the `encodings` extension expands CSV's `encoding :=` support, while ICU handles collations and
time zones rather than arbitrary byte decoding.

Use a distinct dollar-quote delimiter absent from the supplied script. Reach for
an interpreter/heredoc template only when the program needs Bash-specific state;
ordinary pipelines execute directly through ShellFS and are easier to inspect.
The MCP shell tool generates UUID-based delimiters. Templates and executable scripts
are trusted code, not an injection boundary.
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
-- The template is a file, references/shellfs_runner.tera (a `run` macro + a `for` loop); SQL reads and renders it.
WITH commands AS (
    SELECT 'ls' AS cmd, '-1 /Users/aloksubbarao/duckdb-skills/server' AS flags, 'header := false, delim := ' || chr(39) || '|' || chr(39) || ', names := [' || chr(39) || 'line' || chr(39) || ']' AS opts
    UNION ALL SELECT 'uname', '-a', 'header := false, delim := ' || chr(39) || '|' || chr(39) || ', names := [' || chr(39) || 'line' || chr(39) || ']'
), program AS (
    SELECT html_unescape(tera_render(t.content, json_object('commands', array_agg({'cmd': cmd, 'flags': flags, 'opts': opts})))) AS statement
    FROM commands, read_text('/Users/aloksubbarao/duckdb-skills/skills/tera/references/shellfs_runner.tera') t GROUP BY t.content
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

## Loops and flags: one page fetched three ways (verified 2026-09-29)

One context drives three templates. Scalars (`url`, `user_agent`, `timeout`, `max_bytes`) become shell flags
in one and `:=` parameters or MAP entries in the others; lists (`headers`, `params` as `[{name, value}]`) are
`{% for %}` loops. `references/fetch_three_ways.sql` renders each `fetch_*.tera`, `html_unescape`s it,
self-dispatches it to `/sql`, and compares the bodies after `::HTML`.

- `fetch_shellfs.tera`: `read_text($cmd$curl -sS --fail --max-time {{ timeout }} --max-filesize {{ max_bytes }} … |$cmd$)`;
  the loops render one `-H` per header and one `--data-urlencode` per param (`--get`). No HTTP status from curl.
- `fetch_http_client.tera`: `http_get(url, MAP {…headers}, MAP {…params})`; the loops render the two MAP literals.
  Its arguments are positional, not `:=`. The JSON receipt is cast to `STRUCT(status, reason, body)`, not extracted.
- `fetch_crawler.tera`: raw `crawl('<url>', …13 named…, max_results := 1)`, params looped into the query string.
  The rendered url is a literal, so the single-URL overload binds; the self-dispatch is what applies it per row.
  `crawl_url` is also allowed when Tera renders the URL as a literal and the statement is self-dispatched. Never
  pass the source column directly; a binding complaint means the dispatch step was skipped. This template prefers
  `crawl()` for its richer receipt, and `max_results := 1` bounds it without an outer `LIMIT`.
- Measured 2026-09-29: shellfs and http_client bodies are identical (274,457 chars, same md5, title `duckpgq –
  DuckDB Community Extensions`, 31 links). The crawler row is a 200 with the same title and 31 links but 274,096
  chars and a different md5: `html.document` is the crawler's normalised copy of the page, 361 chars shorter.
- Keep a failed dispatch as a row: `CASE WHEN receipt.status = 200 THEN from_json(body, …) ELSE [{… 'error':
  receipt.body}] END` before `unnest`, or the failing method silently disappears.
- `html_extract_text` takes XPath: `'//title'`, not `'title'` (that returned `[]`).

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

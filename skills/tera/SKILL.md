---
name: tera
description: Render inline or named Tera templates through the selected DuckDB MCP. Use for generated SQL and shell programs whose shape repeats; not to wrap simple commands.
argument-hint: "[template path or render error]"
allowed-tools: mcp__dev__query, mcp__dev__execute
---

# Tera

Tera fills holes; SQL decides. The first CTE declares every value (rows, the command as text, reader
options as text, values prequoted with `quote_literal`); `tera_render(template, row::JSON, autoescape := false)`
substitutes them; `array_agg(selfdispatch(sql))` and `CROSS JOIN UNNEST` run them. A template has no
`{% if %}`, no `{% for %}` over options, no macros, no `default` filters and no business logic: a value that
varies is a column, an option list that varies is a different text column per row.

Pick a template by shape. The five canonical ones are in
[../self-dispatch/templates/](../self-dispatch/templates/canonical.sql) (shell, pipeline, sql, network, loop), each
with a verified example. Anything else is an inline template:
[../self-dispatch/references/inline.sql](../self-dispatch/references/inline.sql). A new template file is
warranted only when the statement's shape is new and reused. Someone without the `.tera` files should be
able to rewrite the query with plain string functions without redesigning it.

## Native call

```sql
INSTALL tera FROM community;
LOAD tera;

-- tera_render(template VARCHAR, context JSON, autoescape BOOLEAN := true, template_path VARCHAR := NULL)
--   template: an inline body, or a file name when template_path (a glob) is given.
--   context: the row as JSON (row::JSON); pass '{}' when there are no variables.
--   autoescape: false for SQL, shell and any non-HTML text.
--   A JSON value in the context renders as [object]; pass text when the template must print JSON.
WITH listings AS (
    SELECT 'read_csv' AS reader, [$c$find '/private/tmp' -maxdepth 0 -type d |$c$] AS sources,
           $o$, header := false, names := ['path']$o$ AS options
)
SELECT tera_render('shell.tera', l::JSON, autoescape := false,
                   template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS sql
FROM listings AS l;
```

A missing-template error means check the glob and the name, not that the extension lacks a file loader.
Inline rendering does not load sibling files.

## Worked references

- `references/gh_open_prs.sql`: one `gh search prs` per account, the account and the field list declared
  in the first CTE, an inline template, receipts unnested.
- `references/shell_readers.sql`: which reader for command output (`read_csv`, `read_json`, `read_lines`,
  `read_text`, `read_blob`), their installed options from `duckdb_functions()`, encodings, pipefail.
- `references/video_frames.tera` / `video_frames.sql`: a video as rows (see below).

Facts kept from earlier fetch experiments (2026-09-29): `html_extract_text` takes XPath (`'//title'`, not
`'title'`, which returns `[]`); `crawl(url, …)` binds when the URL is a rendered literal, so the dispatch is
what applies it per row; shellfs curl and `http_get` returned identical bodies, crawler's `html.document` is
its normalised copy. A launchd plist is `plutil -convert xml1 -o out.plist in.json`, not a template.

## Quoting and pipelines

Use a dollar-quote tag absent from the enclosed text. Plain ShellFS pipelines report the last command's
status and can hide an upstream failure; run `bash -o pipefail -c` when that matters. Templates are trusted
code, not an injection boundary: external values are prequoted in SQL (`quote_literal`) before rendering.
HTML escaping is neither SQL nor shell quoting.

## Measured limits and diagnostics

- `date` and `urlencode` filters are absent in this build (retested 2026-09-28).
  Use native SQL formatting and URL functions.
- Missing variables fail; JSON null renders empty. Declare every value; do not lean on `default(value=...)`.
- Use the two-argument overload even for an empty context: the one-argument overload
  was observed to ignore `autoescape := false`.
- Tera's `//` and arithmetic involving parenthesized filters were unsupported. Compute those values in SQL.
- The installed function is marked side-effecting. If DuckDB refuses reuse of
  its alias in the same projection, consume it in the next CTE.
- A parse error names template syntax and a line/column; a render error names missing context or
  templates. Inspect the inner cause.
- Keep the generated SQL beside its receipt when anything downstream needs it. A render result is not
  proof that its SQL ran. No automatic retry after an uncertain write.

Readers bring their own columns: `read_csv`/`read_json` sniff; never `columns := {...}`, never a single
VARCHAR column for structured stdout. A streaming LIMIT can terminate an upstream command: a preview does
not certify all side effects completed.

Sources: [extension and cookbook](https://query.farm/products/extensions/tera/),
[function reference](https://query.farm/products/extensions/tera/functions/category/render/).

## Worked reference: a video as rows

`references/video_frames.tera` returns one row per frame (`second, path, phash`) from a `read_csv` over a pipe
whose producer is a heredoc program (macOS AVFoundation via `swift -`) writing one JPEG per frame at a chosen
rate; `pic_phash` runs per row as the stream arrives. `references/video_frames.sql` is one query: it dispatches
pass one, splits its receipts' frames into scenes, dispatches pass two per busy scene, and returns the scenes over
both passes' frames. See the `watch-video` skill.

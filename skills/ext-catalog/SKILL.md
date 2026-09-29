---
name: ext-catalog
description: >
  Search stored DuckDB extension READMEs with glob patterns, read relevant lines through
  ScalarFS, or parse Markdown/HTML into DuckBlocks. Discover extension functions and all
  documented parameters before inspecting runtime signatures. Raw responses stay available.
argument-hint: "[extension name | glob | function or parameter]"
allowed-tools: mcp__dev__ext_docs, mcp__dev__query_with_limit
---

# Extension catalog

Use the selected dev service at `http://localhost:9495/sql`. `agents.ext_docs` is the
agent entrypoint: `SELECT extension_name, readme FROM agents.ext_docs`.
The MCP tool `ext_docs(extension)` returns a complete README; for a specific question, query matching
lines or blocks first. Do not dump a whole README or save it to a temporary file to search it.

Preserve raw source data as a general rule. Derive parsed fields, previews and search indexes
from it. An existing authoritative source does not require another raw copy. Never replace
missing values with empty strings; `nullif(value, '')` can normalize genuinely empty values.

## Glob search and line context

Install and load the needed community extensions on the selected connection. These calls
are idempotent; a missing extension is a reason to install it, not stop.

```sql
INSTALL read_lines FROM community; LOAD read_lines;
INSTALL scalarfs FROM community; LOAD scalarfs;

SELECT extension_name
FROM agents.ext_docs
WHERE extension_name GLOB '*lines*'
ORDER BY extension_name;

SELECT e.extension_name, l.line_number, l.content
FROM agents.ext_docs e
CROSS JOIN LATERAL read_lines_lateral(to_scalarfs_uri(e.readme), NULL, 'right') l
WHERE e.extension_name GLOB '*lines*'
  AND l.content GLOB '*Parameter*'
ORDER BY e.extension_name, l.line_number;
```

`GLOB` supports `*`, `?` and character classes and is case-sensitive. Apply `lower()` to
the searched text with a lowercase pattern when case should not matter. The same pattern
works across all stored READMEs by omitting the extension-name predicate.

Self-dispatch is the default general composition pattern: source rows generate complete SQL
statements, scalar posts execute each statement on the selected service, and receipts remain
attached to their input rows. Column values become literals inside independently bound table
function calls, bypassing the outer query's column/lateral binding restrictions. It need not
wait for a binder error. Valid function names, signatures and SQL are still required inside
each statement; preserve and inspect the returned errors.

The correlated lateral example above is also verified. After finding a line, its second
argument can be a range or context selection such as `'203 +/-12'`. The installed lateral
reader accepts the path column but requires a literal line selection; self-dispatch supports
a different selection per source row. Always order returned lines explicitly. Put filesystem
patterns directly in readers, such as `read_lines('/explicit/root/**/*.sql')`, rather than
enumerating them with `glob()` first.

For the full named-parameter API, capture a single README and read it in the **same SQL body**:

```sql
COPY (SELECT readme::VARCHAR FROM agents.ext_docs WHERE extension_name = 'read_lines')
TO 'variable:catalog_readme' (FORMAT variable, LIST none);

SELECT line_number, content
FROM read_lines('variable:catalog_readme',
    lines := {start: 207, stop: 214}, "trim" := 'right')
ORDER BY line_number;
```

`read_lines` parameters: `lines`, `trim`, `before`, `after`, `context`, `ignore_errors`.
Selections include line numbers/lists, ranges, head/tail, context strings, and structs with
`start`, `stop`, `line`, `lines`, `before`, `after`, `context`, `inclusive`.
`trim` accepts `none`, `endings`, `right`, `left`, `both`, or booleans. Quote the named
`"trim"` parameter because it is SQL syntax. Defaults preserve line endings; trimming affects
content, not line numbers or byte offsets. `ignore_errors := true` skips unreadable/invalid
UTF-8 input, so leave it false when fidelity matters. Paths also accept filesystem globs.

ScalarFS provides `to_scalarfs_uri(content)` for inline content, `variable:name` for a stored
value, `pathvariable:name` for stored paths, and `to_pathmacro_url()` for an approved primitive
resolver. Variables are connection-local and do not cross MCP requests or self-dispatches.
Use these helpers rather than temporary files or manual URI/SQL escaping.

## README to DuckBlocks

```sql
INSTALL markdown FROM community; LOAD markdown;

SELECT e.extension_name, b.*
FROM agents.ext_docs e
CROSS JOIN UNNEST(parse_markdown_to_duck_blocks(e.readme)) t(b)
WHERE e.extension_name = 'read_lines'
  AND b.element_type = 'table'
  AND b.content GLOB '*ignore_errors*'
ORDER BY b.element_order;
```

This returns the complete parameter table as one block: `content` holds JSON `headers` and
`rows`; `encoding` is `json`. Filter headings, code, paragraphs, or tables as needed while
retaining `kind`, `element_type`, `content`, `level`, `encoding`, `attributes`, `element_order`.
The scalar Markdown parser accepts the README column directly. For actual Markdown paths,
`read_markdown_blocks` and `read_markdown_sections` provide file/glob readers; consult the
stored `markdown` README for section modes and parameters. ScalarFS-backed paths did not
work with those two readers in the current build; the verified scalar parser avoids that
reader limitation without copying content.

For the **entire saved HTML page**, including content outside the README:

```sql
INSTALL webbed FROM community; LOAD webbed;

SELECT c.extension_name, b.*
FROM agents.ext_catalog c
CROSS JOIN UNNEST(html_to_duck_blocks(parse_html(c.github->>'body'))) t(b)
WHERE c.extension_name = 'read_lines'
  AND b.element_type = 'heading'
ORDER BY b.element_order;
```

`duck_blocks_to_md(blocks)` renders ordered blocks back to Markdown. Parsing is a derived
representation: it does not replace the saved raw HTML or the source README.

## Stored layers and refresh

| Object | Contents |
|---|---|
| `agents.ext_page` | Table, one row per fetched url: `url`, `fetched_at`, `response` (http_get JSON: status, headers, body) |
| `agents.ext_url` | View: `extension_name`, `kind` (community, github, yaml), `url`, read off the list page |
| `agents.ext_catalog` | View: PIVOT of `ext_page`, one row per extension with a `community`, `github` and `yaml` response |
| `agents.ext_docs` | View: extension name and README (the GitHub `<article>` parsed by webbed) |
| `agents.ext_stale` | View: urls missing or older than three days |

`~/duckdb-skills/server/ext_catalog.sql` fetches every url in `ext_stale` into `ext_page`. Startup loads it and cron runs hourly (`0 15 * * * *`); pages
expire after three days. With nothing stale a run fetches and writes nothing. Reuse raw
responses to add parsed columns. Catalog lookup comes first; inspect runtime signatures only
to resolve a documentation gap or version mismatch, since READMEs may omit details.

Verified on dev on 2026-09-24: glob search, correlated ScalarFS line reads, named line
selection through a connection variable, the six-parameter Markdown table, saved JSON
blocks, and full saved HTML to DuckBlocks. No recrawl or duplicate raw table was needed.

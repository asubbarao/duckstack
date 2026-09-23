---
name: ext-catalog
description: >
  The DuckDB community extension catalog on dev — every extension's community page, README and
  function tables, parsed into rows. Use before using an extension you have not used today, when
  asked what an extension does or which functions/settings/parameters it has, when choosing an
  extension for a job, or when the user half-remembers a name ("mini something", "the js one") —
  find it with contains() on agents.ext_catalog, never by guessing or web search. MCP tool:
  ext_docs. Read this instead of guessing parameters or fetching the docs site.
argument-hint: "[extension name | half-remembered fragment]"
allowed-tools: mcp__dev__ext_docs, mcp__dev__query
---

# ext-catalog

The catalog lives on dev, built by crawler × webbed from duckdb.org's community extension list,
each extension's page, and its GitHub README. 270 extensions; 248 have parsed function tables
(2026-09-22).

## Found from a half-remembered name

"There's textplot, but there's another, mini something" is a lookup, not a research task:

```sql
-- the `query` tool; contains(string, search) — plain substring, no LIKE, no regex
SELECT extension_name, github_repo
FROM agents.ext_catalog
WHERE contains(extension_name, 'mini') OR contains(extension_name, 'js')
ORDER BY extension_name;
-- minijinja, miniplot, quickjs, jsonata, … (verified 2026-09-22)

-- or by what it does: the function names, across every extension
SELECT array_agg(DISTINCT extension_name || '.' || function_name) AS hits
FROM agents.ext_catalog_functions
WHERE contains(function_name, 'chart');
-- [miniplot.bar_chart, miniplot.line_chart, miniplot.area_chart, miniplot.scatter_chart, miniplot.scatter_3d_chart]
```

Then `INSTALL <name> FROM community; LOAD <name>;` in your own `:memory:` client — always
allowed — and check `duckdb_functions()` for the real signatures.

## The call (the `dev` MCP)

`ext_docs(extension)` — the extension's community page, then its GitHub README, as ordered
blocks: `element_type` is `paragraph`, `code`, `table` (the function and settings tables arrive
as JSON with `headers` and `rows`), `link`, and so on. Read the `code` blocks for usage and the
`table` blocks for every function, overload and setting.

**The output is large** (about 200 blocks for a typical extension). When the harness saves it to
a file instead of showing it, search that saved file for the function name or the word you need
rather than paging through it, and read only the blocks around the hit.

## The tables, for anything else (the `query` tool)

| table | one row per |
|---|---|
| `agents.ext_catalog` | extension: `extension_name`, `github_repo`, `metadata` (JSON), `community_blocks`, `community_tables`, `github_blocks`, `github_tables`, `github_markdown`, the fetch statuses and `fetched_at` |
| `agents.ext_catalog_functions` | row of a function table: `extension_name`, `function_name`, `function_type`, `description`, `examples`, plus the table's `headers` / `row_data` |
| `agents.ext_catalog_function_docs` | view over the function rows |
| `main.ext_blocks`, `main.ext_readme` | block of an extension's page / README (the crawl's landed layers) |
| `main.ext_catalog_frontier` | the crawl's frontier view over the community list |

```sql
-- which extensions mention a word anywhere in their README
SELECT e.extension_name, len(array_agg(b.element_order)) AS blocks
FROM agents.ext_catalog e, unnest(e.github_blocks) AS t(b)
WHERE contains(lower(b.content), 'parquet')
GROUP BY ALL ORDER BY blocks DESC;
```

Verified 2026-09-22: `ext_docs('scalarfs')` returned the page blocks including its function and
settings tables; the name and function lookups above returned the rows shown.

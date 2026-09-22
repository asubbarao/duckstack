---
name: ext-catalog
description: >
  The DuckDB community extension catalog on dev — every extension's page, README and GitHub
  metadata, parsed into rows. Use before using an extension you have not used today, when asked
  what an extension does or which functions/settings/parameters it has, or when choosing an
  extension for a job. MCP tool: ext_docs. Read this instead of guessing parameters or fetching
  the docs site.
argument-hint: "[extension name]"
allowed-tools: mcp__dev__ext_docs, mcp__dev__query
---

# ext-catalog

The catalog lives on dev, built by crawler × webbed from duckdb.org's community extension list,
each extension's page, and its GitHub README.

## The call (the `dev` MCP)

`ext_docs(extension)` — the extension's README, then its duckdb.org page, as ordered blocks:
`element_type` is `paragraph`, `code`, `table` (the function and settings tables arrive as JSON
with `headers` and `rows`), `link`, and so on.

Read the `code` blocks for usage and the `table` blocks for every function, overload and setting.

## The tables, for anything else (the `query` tool)

| table | one row per |
|---|---|
| `ext_catalog` | extension: `extension_name`, `description`, `version`, `language`, `license`, `gh_repo`, `gh_ref` |
| `ext_github` | extension's repo: stars, forks, open issues, `pushed_at`, `archived` |
| `ext_blocks` | block of the extension's duckdb.org page |
| `ext_readme` | block of the extension's GitHub README |
| `ext_frontier` | extension on the community list (the crawl's to-do list) |

```sql
-- which extensions mention a word anywhere in their README
SELECT extension_name, len(array_agg(block_order)) AS blocks
FROM ext_readme WHERE contains(lower(content), 'parquet')
GROUP BY extension_name ORDER BY blocks DESC;
```

Verified 2026-09-22: `ext_docs('scalarfs')` returned the page blocks including its function and
settings tables; 95 extensions are in `ext_catalog`.

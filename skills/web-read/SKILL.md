---
name: web-read
description: Cookbook for reading the web in DuckDB — fetch any page or API with curl through shellfs, cast the body (::HTML, ::JSON) and parse it with webbed (readable blocks, links), shape JSON with JSONata, compute with QuickJS, render with tera. Use when asked to read a docs page, a URL, a GitHub/REST API, or to turn fetched content into rows or text, without dumping raw HTML into context.
allowed-tools: mcp__dev__query
---

# Reading the web in DuckDB

Every recipe below ran on 2026-10-17 exactly as written (shellfs, webbed, jsonata, quickjs, tera loaded). The shape
is always the same: fetch with curl through shellfs → keep the raw response → **cast the body to its type** →
whole-document parsing → select what you need. A page you will read again lands in `lake.agents.ext_fetch`
first (the crawl skill), and is parsed from there.
Raw HTML never goes into context: an 82,892-character docs page is 652 typed blocks; read those.

The casts are written out even where a function would accept VARCHAR: `(body)::HTML` makes the value a webbed
HTML document, so every html_* function after it operates on a typed column, and the next reader sees what the
column is. Same for `::JSON`.

## 1. A web page → readable blocks and links (curl + webbed)

```sql
-- html_to_duck_blocks(html HTML) -> STRUCT(kind, element_type, content, level, encoding, attributes MAP, element_order)[]
-- html_extract_links(html HTML) -> STRUCT(text, href, title, line_number)[]
WITH fetched AS (
    SELECT 'https://duck-tails.readthedocs.io/en/latest/guide/lateral-joins/' AS url, content::HTML AS html
    FROM read_text('curl -sSL --fail --max-time 30 https://duck-tails.readthedocs.io/en/latest/guide/lateral-joins/ |')
), parsed AS (
    SELECT url, length(html::VARCHAR) AS raw_chars, html_to_duck_blocks(html) AS blocks, html_extract_links(html) AS links
    FROM fetched
)
SELECT url, raw_chars, len(blocks) AS n_blocks, len(links) AS n_links, b.element_type AS type, trim(b.content) AS text
FROM parsed CROSS JOIN UNNEST(blocks) AS u(b)
WHERE b.kind = 'block' AND b.element_type IN ('paragraph', 'code', 'heading', 'table')
LIMIT 3;
-- 82892 chars | 652 blocks | 209 links; code blocks come back as code, tables as JSON {headers, rows}
```

`--fail` turns a 404 into a reader error, so an error page never becomes rows. Dev publishes no `web_read`
tool (2026-10-09); run this query. Do not wrap a page you will serve in `parse_html` — it voids `<script src>`.

## 2. A JSON API (GitHub REST here) → shaped with JSONata

```sql
INSTALL jsonata FROM community;
LOAD jsonata;
-- jsonata(expression VARCHAR, json_data JSON [, bindings JSON]) -> JSON
WITH releases AS (
    SELECT content::JSON AS body
    FROM read_text($cmd$curl -sSL --fail --max-time 30 -H 'Accept: application/vnd.github+json' 'https://api.github.com/repos/duckdb/duckdb/releases?per_page=3' |$cmd$)
)
SELECT jsonata('$.{"tag": tag_name, "published": published_at, "assets": $count(assets)}', body) AS picked
FROM releases;
-- [{"assets":29,"published":"2026-09-28T13:35:11Z","tag":"v1.5.6"}, …]
```

For GitHub, repo **files** are read over HTTPS the same way: `read_json` on the API tree, `read_text` on raw
files, no clone. The REST API is for issues, releases, runs and the like. Private repos: `gh … --json … |`
through shellfs (never `gh api` file fetches), or a token from `getenv` in a curl `-H`, never pasted.

## 3. QuickJS — JavaScript on a value

```sql
INSTALL quickjs FROM community;
LOAD quickjs;
-- quickjs_eval(function VARCHAR, args...) -> JSON; a JSON argument arrives as a string, so JSON.parse it
-- releases_picked: section 2's query, as a CTE
SELECT quickjs_eval('(rows) => JSON.parse(rows).map(r => r.tag).sort()', picked) AS tags_sorted FROM releases_picked;
-- ["v1.5.4","v1.5.5","v1.5.6"]
```

Use it for what JS is good at (sorting objects, string munging, SVG for charts), with the data passed as an
argument, never concatenated into the code.

## 4. tera — render text or HTML from rows

```sql
-- tera_render(template VARCHAR [, context JSON]) -> VARCHAR; the row is the context, SQL does the joining
SELECT string_agg(tera_render('{{ tag }} ({{ published }})', release, autoescape := false), '; ' ORDER BY i) AS rendered
FROM releases_picked CROSS JOIN UNNEST(picked::JSON[]) WITH ORDINALITY AS t(release, i);
-- v1.5.6 (2026-09-28T13:35:11Z); v1.5.5 (2026-07-22T10:51:50Z); v1.5.4 (2026-06-17T10:45:53Z)
```

## Rules that keep context small and the SQL honest

- Start at `LIMIT 3`; widen when the shape is right.
- Whole-document readers (`html_to_duck_blocks`, `html_extract_links`, `read_html`, `jsonata` over the whole body)
  before any selector; a hand-written xpath/css/jsonpath per column means the shape is not understood yet.
- Many URLs: one row per URL, self-dispatched, one literal `read_text('curl … |')` statement per row, landed in
  `lake.agents.ext_fetch` (the crawl skill's `references/crawl_rows.sql`), with its limits stated.
- A missing extension is `INSTALL x FROM community; LOAD x;`, then continue. `jsonata` and `quickjs` are
  installed on dev but not loaded at boot.

---
name: web-read
description: Cookbook for reading the web in DuckDB — fetch any page or API with http_client, cast the body (::HTML, ::JSON) and parse it with webbed (readable blocks, links), shape JSON with JSONata, compute with QuickJS, render with tera. Use when asked to read a docs page, a URL, a GitHub/REST API, or to turn fetched content into rows or text, without dumping raw HTML into context.
allowed-tools: mcp__dev__query
---

# Reading the web in DuckDB

Every recipe below ran on the dev server on 2026-09-28 exactly as written. The shape is always the same:
fetch → keep the raw response → **cast the body to its type** → whole-document parsing → select what you need.
Raw HTML never goes into context: an 82,892-character docs page is 652 typed blocks; read those.

The casts are written out even where a function would accept VARCHAR: `(body)::HTML` makes the value a webbed
HTML document, so every html_* function after it operates on a typed column, and the next reader sees what the
column is. Same for `::JSON`.

## 1. A web page → readable blocks and links (http_client + webbed)

```sql
-- http_get(url VARCHAR [, headers MAP(VARCHAR, VARCHAR), params MAP(VARCHAR, VARCHAR)]) -> JSON {status, reason, body}
-- html_to_duck_blocks(html HTML) -> STRUCT(kind, element_type, content, level, encoding, attributes MAP, element_order)[]
-- html_extract_links(html HTML) -> STRUCT(text, href, title, line_number)[]
WITH fetched AS (SELECT http_get('https://duck-tails.readthedocs.io/en/latest/guide/lateral-joins/') AS response),
page AS (SELECT response ->> '$.status' AS status, (response ->> '$.body')::HTML AS html FROM fetched),
parsed AS (SELECT status, length(html::VARCHAR) AS raw_chars, html_to_duck_blocks(html) AS blocks, html_extract_links(html) AS links FROM page)
SELECT status, raw_chars, len(blocks) AS n_blocks, len(links) AS n_links, b.element_type AS type, trim(b.content) AS text
FROM parsed CROSS JOIN UNNEST(blocks) AS u(b)
WHERE b.kind = 'block' AND b.element_type IN ('paragraph', 'code', 'heading', 'table')
-- 200 | 82892 | 652 blocks | 209 links; code blocks come back as code, tables as JSON {headers, rows}
```

The dev MCP tool `web_read(url)` is this query. Keep `status`: a 404 page is also HTML.
Do not wrap a page you will serve in `parse_html` — it voids `<script src>`.

## 2. A JSON API (GitHub REST here) → shaped with JSONata

```sql
-- jsonata(expression VARCHAR, json_data JSON [, bindings JSON]) -> JSON
WITH fetched AS (SELECT http_get('https://api.github.com/repos/duckdb/duckdb/releases?per_page=3',
        MAP {'Accept': 'application/vnd.github+json', 'User-Agent': 'duckdb'}, MAP {}) AS response),
releases AS (SELECT response ->> '$.status' AS status, (response ->> '$.body')::JSON AS body FROM fetched)
SELECT status, jsonata('$.{"tag": tag_name, "published": published_at, "assets": $count(assets)}', body) AS picked
FROM releases
-- [{"tag":"v1.5.6","published":"2026-09-28T13:35:11Z","assets":29}, …]
```

For GitHub, reading repo **files** is duck_tails over a bare clone (`git_tree` + `git_read_each(t.git_uri)`);
the REST API is for issues, releases, runs and the like. Private repos: `gh api … |` through shellfs, or a token
in the headers MAP from `getenv`, never pasted.

## 3. QuickJS — JavaScript on a value

```sql
-- quickjs(code VARCHAR) -> VARCHAR   (quickjs_eval(function VARCHAR) for a function body)
SELECT quickjs('JSON.stringify(' || picked::VARCHAR || '.map(r => r.tag).sort())') AS tags_sorted
-- ["v1.5.4","v1.5.5","v1.5.6"]
```

Use it for what JS is good at (sorting objects, string munging, SVG for charts), with the data concatenated in.

## 4. tera — render text or HTML from rows

```sql
-- tera_render(template VARCHAR [, context JSON]) -> VARCHAR
SELECT tera_render('{% for r in releases %}{{ r.tag }} ({{ r.published }}){% if not loop.last %}; {% endif %}{% endfor %}',
    json_object('releases', picked)) AS rendered
-- v1.5.6 (2026-09-28T13:35:11Z); v1.5.5 (2026-07-22T10:51:50Z); v1.5.4 (2026-06-17T10:45:53Z)
```

## Rules that keep context small and the SQL honest

- Start at `LIMIT 3`; widen when the shape is right. `/sql` returns 20 rows unless you give an explicit LIMIT.
- Whole-document readers (`html_to_duck_blocks`, `html_extract_links`, `read_html`, `jsonata` over the whole body)
  before any selector; a hand-written xpath/css/jsonpath per column means the shape is not understood yet.
- Build any generated URL or statement by `||` concatenation; no printf, no doubled quotes.
- Many URLs: one row per URL, `http_get(url)` is a scalar, so it runs per row with no self-dispatch; land the raw
  responses (a table or files under raw/) before parsing if they will be read twice.
- A missing extension is `INSTALL x FROM community; LOAD x;`, then continue.

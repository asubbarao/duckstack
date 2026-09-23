---
name: live-page
description: >
  Make a web page fast with DuckDB alone: tera for the HTML, quickjs for SVG charts (any JS),
  crawler's css_select to check, pull or serve one block of HTML, jsonata to reshape rows into the
  page's JSON. It writes one self-contained .html (opens from file://, uploads to Slack) and can
  serve it live through quackapi, so each browser refresh re-runs the SQL. Use for any HTML page,
  analysis page, writeup, report, one-pager, dashboard, "chart that", comparison with charts,
  "zeroload" page, "liverender" / live-render page or live page, whatever the data source: a CLI
  or API through shellfs, a read-only Postgres, crawled web pages, or files. Short verified
  snippets, not templates; the analysis supplies the data and the words (e.g. ci-timing for CI/CD).
argument-hint: "<what the page shows> [data source]"
allowed-tools: Bash, mcp__dev__render
---

Read `/duckstack:duck` first; its SQL rules apply. This skill covers only how a page gets made.
The analysis supplies its own relations and prose. An example analysis is `/duckstack:ci-timing`,
which covers CI/CD and duck_hunt.

**Where it runs.** Use this doc in your own `duckdb :memory:`, or run `uvx --from duckdb duckdb`
for anything a teammate re-runs. The `dev` MCP has one related tool: `render(template, ctx)` returns
`tera_render` of a template file on dev. No MCP tool or Python entrypoint serves pages. No macros.

## Start any page

1. **Inputs → views.** Land every response under `raw/` with a UTC timestamp and never overwrite
   it. The views read `raw/`.
2. **Finish every number in SQL**: labels, durations, pixel widths, links. Use jsonata when the job
   is only reshaping JSON.
3. **Charts:** `quickjs(js || rows_json)` → an SVG string, one per chart.
4. **Page:** `CREATE VIEW page_html AS SELECT tera_render(template, ctx, autoescape := false) AS html`.
   It is a view, so every read re-renders it.
5. **Out:** `COPY (FROM page_html) TO 'page.html' …` for the file, and/or `CREATE ROUTE page GET '/' AS
   FROM page_html` + `quackapi_serve(…, block := true)` to serve it live.

**Zeroload** means no build step and no app: one `.sql` file, DuckDB, and the community extensions
the file installs itself (`INSTALL x FROM community; LOAD x;` at the top). The data is baked into
the file, or DuckDB fetches it when the page is served.

## Inputs, any source → a view

```sql
INSTALL shellfs FROM community; LOAD shellfs;
INSTALL crawler FROM community; LOAD crawler;
-- CLI / API through shellfs: the command's stdout is the file; tee keeps the raw response
-- read_json(path, format := 'auto', records := 'auto', filename := false, columns := NULL, maximum_depth := -1, sample_size := 20480, ignore_errors := false)
CREATE OR REPLACE VIEW raw_runs AS
FROM read_json('ts=$(date -u +%Y%m%dT%H%M%SZ); gh run list --repo o/r --json databaseId,url,createdAt | tee raw/runs-$ts.json |');
-- landed files, newest copy per key wins
CREATE OR REPLACE VIEW runs AS FROM read_json('raw/runs-*.json', filename := true)
QUALIFY row_number() OVER (PARTITION BY databaseId ORDER BY filename DESC) = 1;

-- a database, read-only: ATTACH … READ_ONLY refuses writes ("attached in read-only mode")
-- InFrame's deployed databases go through /db-connect (a read-only tunnel); never write to them
INSTALL postgres; LOAD postgres;
ATTACH 'host=localhost dbname=postgres' AS pg (TYPE postgres, READ_ONLY);

-- the web: crawler for many pages (/duckstack:crawl); one page is read_text + css_select
-- css_select(html VARCHAR, selector VARCHAR, mode VARCHAR) -> VARCHAR ; mode 'text' | 'html' | 'attr:<name>'
SELECT css_select(content, 'title', 'text') AS title FROM read_text('https://duckdb.org/');
```

Verified 2026-09-23. The Postgres ATTACH listed 208 tables, and a `CREATE` through it was refused.
`css_select` returned the page title.

## Reshape: jsonata (optional)

`jsonata(expression, json_data[, bindings]) -> JSON` turns one query result into the JSON the
chart or template wants, in a single expression: series, a max, nested sections, a sorted list.

```sql
INSTALL jsonata FROM community; LOAD jsonata;
CREATE OR REPLACE VIEW page_data AS
SELECT jsonata('($m := $max(r.v); {"total": $sum(r.v), "top": r[v = $m].name,
                 "bars": r^(>v).{"label": name, "v": v, "url": url}})',
               to_json({r: list({name: name, v: v, url: url})})) AS j
FROM items;
-- → {"total":63,"top":"beta","bars":[{"label":"beta","v":30,…},…]}
```

Use plain SQL for anything that is really a join, a filter or an aggregate over tables. jsonata
sits last, turning finished rows into a shape. `$max(%.v)` inside a predicate returned nothing
here; bind it first with `$m := …`.

## Charts: quickjs

`quickjs(code) -> VARCHAR` evaluates the script and returns its last expression. Splice the rows in
as a JSON literal and return an SVG string. The page then holds the chart as static text, with no
CDN and no script tag.

```sql
INSTALL quickjs FROM community; LOAD quickjs;
CREATE OR REPLACE VIEW chart AS
SELECT quickjs($js$
const d = $js$ || j::VARCHAR || $js$;
const top = Math.max(...d.bars.map(b => b.v)), esc = s => String(s).replaceAll('&', '&amp;').replaceAll('<', '&lt;');
`<svg viewBox="0 0 520 ${d.bars.length * 24}" width="100%" role="img">` + d.bars.map((b, i) =>
  `<a href="${esc(b.url)}"><text class="lbl" x="0" y="${i * 24 + 15}">${esc(b.label)}</text>` +
  `<rect class="bar${i === 0 ? ' hot' : ''}" x="90" y="${i * 24 + 4}" width="${Math.round(b.v * 380 / top)}" height="15"/></a>`).join('') + `</svg>`
$js$) AS svg
FROM page_data;
```

- **Classes, not colours** (`bar`, `hot`). The page's CSS colours them, dark mode included.
- **Wrap each mark in `<a href>`** so a bar or dot links to its source row.
- **Escape label text in JS** with `replaceAll`.
- **Several chart kinds:** put the functions (hbar, strip, stacked, gantt) in one `$js$` string
  in a view. Each chart is then `quickjs(lib || 'hbar(' || rows_json || ')')`.
- **miniplot** (`bar_chart(labels, values, title[, 'file.html'])`) writes a stock Plotly page that
  loads from a CDN. Use it only when the chart must be interactive.

## Render: tera

```sql
INSTALL tera FROM community; LOAD tera;
-- tera_render(template VARCHAR, context JSON, autoescape := true) -> VARCHAR
CREATE OR REPLACE VIEW page_html AS
SELECT tera_render($tpl$<!doctype html><html><head><meta charset="utf-8"><title>Items</title><style>…</style></head>
<body><section id="top"><h1>{{ d.top }} leads</h1>{{ svg }}<p>{{ d.top }} is the largest of {{ d.bars | length }}; together they total {{ d.total }}.</p></section>
<section id="detail"><table>{% for b in d.bars %}<tr><td><a href="{{ b.url }}">{{ b.label }}</a></td><td>{{ b.v }}</td></tr>{% endfor %}</table></section>
</body></html>$tpl$, {d: j, svg: svg, generated: strftime(timezone('UTC', now()), '%Y-%m-%d %H:%M UTC')}::JSON, autoescape := false) AS html
FROM page_data, chart;
```

| Gotcha | Do instead |
|---|---|
| No `//` operator. Filters bind looser than arithmetic, and `(x \| f) * n` is a parse error | compute durations, widths and percentages in SQL (`printf('%dm %02ds', s // 60, s % 60)`) |
| `escape` throws on a null or a number | `autoescape := false` and escape in SQL or JS; `coalesce` nulls in SQL |
| A context field or view aliased as an existing table name binds to that table's struct and fails with odd `+(STRUCT…)` errors | give aliases unique names |
| No file loader, so `include`, `extends` and `import` fail | keep the template inline as `$tpl$…$tpl$`, or read it with `read_text`; use `{% macro %}` for repeats |
| No `date`, `now()` or `urlencode` in the template | `strftime`, `url_encode` in SQL |
| A missing variable is an error | `{{ x \| default(value="…") }}`; `{{ __tera_context }}` dumps what arrived |

The full engine reference, with error bisection and minijinja, is `/duckstack:tera`.

## css_select: check, pull, serve a block

```sql
INSTALL crawler FROM community; LOAD crawler;
-- check what the page actually says (the rendered text, links in charts)
SELECT css_select(html, '#top p', 'text'), css_select(html, 'svg a', 'attr:href') FROM page_html;
-- pull a block out of another page into this one's context
SELECT css_select(content, '#detail', 'html') AS block FROM read_text('old/page.html');
```

- **`'html'` mode re-serializes** the node: a `<table>` comes back with `<tbody>` added. It is not a
  byte-for-byte slice of the source, so do not `replace()` with it. To swap one block, render it
  as its own string in the context.
- **No match** returns `''`, not NULL.
- **An unknown mode** behaves as `'text'`.

## Out: the file, and the live page

**The file.** Every teammate can use it.

```sql
COPY (FROM page_html) TO 'page.html' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
```

```bash
uvx --from duckdb duckdb -c ".read page.sql" && open page.html
```

**Live.** quackapi serves the same view, and each request re-runs it.

```bash
uvx --from duckdb duckdb -c ".read page.sql" \
  -c "INSTALL quackapi FROM community; LOAD quackapi" \
  -c "CREATE OR REPLACE ROUTE page GET '/' AS FROM page_html" \
  -c "CREATE OR REPLACE ROUTE section GET '/section/:id' AS SELECT css_select(html, '#' || \$id, 'html') AS html FROM page_html" \
  -c "FROM quackapi_serve(8766, host := '127.0.0.1', query_timeout_ms := 120000, block := true)"
# open http://127.0.0.1:8766/   (GET /health answers once it is up)
# stop: Ctrl-C, or  kill $(lsof -ti tcp:8766 -sTCP:LISTEN)
```

Verified end to end on 2026-09-23 (DuckDB 1.5.5, quackapi ed4552b):
- `GET /` returned `text/html` and `/section/top` returned the one block.
- After a new `raw/items-*.json` landed, the next request showed it ("beta leads" became "delta leads").
- `kill` freed the port.

On a CI page, one refresh picked up two new runs (29 → 31) once the jobs fetch went stale.

What makes live work:

- **A single column named `html` is served as `text/html`.** Any other shape comes back as JSON rows.
- **Routes run on other connections.** They see views and ordinary tables, but not `TEMP` tables
  or `getvariable()`/`SET VARIABLE`. Keep everything the page reads in views and non-temp tables.
- **Every request re-runs the views.** A glob sees new files, and a shellfs view re-runs its
  command twice per reference (bind and execute). Gate an expensive fetch on the age of the newest
  raw file, as in `find raw -name 'x-*.json' -mmin -30 | grep -q . || <fetch>; cat $(ls -t raw/x-*.json | head -1)`.
  Parse inputs that never change (landed logs, files) once into a table.
- **`query_timeout_ms` defaults to 30 s.** A slower request gets a 504, so raise the timeout when a
  refresh may fetch.
- **`block := true` needs quackapi ed4552b or later.** On older builds the binder reports
  `Invalid named parameter "block"`; run `FORCE INSTALL quackapi FROM community` once.

## What the page looks like

- **Top of the page:** one or two charts and a short plain paragraph that states the answer with
  its numbers. This is the part people screenshot.
- **Below it:** the details, tables, and how the data was measured.
- **Every number links to its source** (a run, a job, a row's URL): the charts through `<a href>`
  around marks, the prose through links on the numbers.
- **Style:**
  - one 760–820px column, IBM Plex Sans and Mono from Google Fonts, everything else inline
  - colour tokens on `:root`, repeated for dark mode under
    `@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {…} }` and
    `:root[data-theme="dark"]`, with an explicit `body` background
  - an amber accent for the one thing that matters
  - a 16px side gutter and no horizontal scroll on a phone

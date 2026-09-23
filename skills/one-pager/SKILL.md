---
name: one-pager
description: >
  Turn a DuckDB analysis into a shareable, self-contained HTML one-pager rendered by DuckDB
  itself: one .sql file that fetches through shellfs, lands raw responses under raw/, builds
  tables and page views, draws charts as SVG with the `quickjs` extension (miniplot second), and
  renders the page with `tera` (tera_render) in the granica memo style — amber Verdict,
  scoreboard card, "What we ran" tiles. No .sh, no Python, no hand-written HTML file, no dash.
  Use when asked for "something to share", "a one pager", "a report page", "a dashboard",
  "charts of X", or when a GUI would be the wrong deliverable. Exemplars:
  takehome-granica analysis/report.html + tera/recommend.sql, and
  ~/inframe/internal/ci/duckdb/slow.sql and review.sql.
argument-hint: "<what the page answers> [data source]"
allowed-tools: Bash
---

Read `/duckstack:duck` first; its process rules (reader first, keep the row, `array_agg` +
`len` over `count`, no macros, one layer at a time) apply here unchanged. This skill adds the
last two steps: charting and rendering. The whole pipeline — fetch, model, chart, render — is
one `.sql` run by DuckDB. A `dash` GUI, a chat summary, a Python plot or an HTML file typed by
hand is not the deliverable.

## 1. The shape of the file

```
x.sql
├── INSTALL/LOAD  shellfs, tera, quickjs (+ zipfs, duck_hunt, duck_tails as needed)
├── 1. fetch      read_json('cmd | tee raw/<name>-$(date -u +%Y%m%dT%H%M%SZ).json |')
├── 2. raw views  read_json('raw/<name>-*.json', filename := true)
├── 3. tables     newest copy per key: QUALIFY row_number() OVER (PARTITION BY key ORDER BY filename DESC) = 1
├── 4. page views everything the template prints, precomputed (text, pixels, labels)
├── 5. charts     one quickjs(...) per chart → an SVG string column
└── 6. render     SET VARIABLE ctx = {…}::JSON;  COPY (SELECT tera_render(…)) TO 'x.html' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '')
```

Run: `duckdb :memory: -c ".read x.sql" && open x.html`. Re-running re-fetches and appends a
new raw file; nothing is overwritten, so the page is reproducible from `raw/` offline. Bash
that the fetch needs lives inside the shellfs string, never in a `.sh` file.

## 2. The granica build recipe (the reference implementation)

`asubbarao/takehome-granica` — read it with `/duckstack:duck-tails`, never `gh api` or curl.
`run.sql` renders `.sql.tera` templates and `.read`s them; `tera/recommend.sql` does the
writing. The recipe it proves:

1. **Every number is a table first.** Measured tables → views that compute the comparison
   (`storage_saved`, `latency_added`, the ratio). Prose never retypes a number.
2. **Each table lands as its own file.** `COPY (SELECT … ORDER BY …) TO 'analysis/rec_trade.md' (FORMAT markdown);`
   — one `.md` per chart or table, readable on its own, diffable in git.
3. **The template gets the tables by name.** Either pre-rendered text keyed by file name, or
   lists of structs the template loops over:

```sql
-- read_text(files) -> filename, content, size, last_modified
-- parse_filename(path, trim_extension := false, separator := 'system')
-- json_group_object(key, value) — one JSON object, keyed by the table's file name
SET VARIABLE ctx = {
  tables: (SELECT json_group_object(parse_filename(filename, true), content)
           FROM read_text('analysis/rec_*.md')),                  -- {{ tables.rec_trade }} in a .md template
  jobs:   (SELECT list(j) FROM page_jobs j),                      -- {% for j in jobs %} in an .html template
  generated: strftime(now(), '%Y-%m-%d %H:%M UTC')
}::JSON;

-- tera_render(template VARCHAR, context JSON, autoescape := true)
COPY (SELECT tera_render((SELECT content FROM read_text('page.html.tera')), getvariable('ctx'), autoescape := false))
  TO 'report.html' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
```

   Verified 2026-09-22: `COPY … (FORMAT markdown)` → `read_text` → `json_group_object` →
   `{{ tables.rec_trade }}` renders the markdown table, `{% for j in jobs %}` loops the structs.
4. **The skeleton is `analysis/report.html`.** Keep the template beside the `.sql` (or inline
   as `$tpl$…$tpl$`); the `.sql` only fills it.
5. **A missing piece degrades, it does not fail:** `{{ tables.x | default(value="_(x not generated in this run)_") }}`.

## 3. Charts — quickjs first, miniplot second, tera-loop SVG as the fallback

**quickjs** (verified 2026-09-22): `quickjs(code)` evaluates the script and returns its last
expression as `VARCHAR`. Splice the rows in as a JSON literal and return an SVG string; the
chart is static text in the page — no CDN, no script tag.

```sql
INSTALL quickjs FROM community; LOAD quickjs;
-- quickjs(code VARCHAR) -> VARCHAR          : last expression, as text
-- quickjs_eval(fn VARCHAR, args ANY...) -> JSON : calls an arrow function; JSON args arrive as strings (JSON.parse them)
CREATE OR REPLACE VIEW chart_jobs AS
SELECT quickjs($js$
const rows = $js$ || (SELECT to_json(list({name: name, v: job_s} ORDER BY job_s DESC)) FROM page_jobs)::VARCHAR || $js$;
const top = Math.max(...rows.map(r => r.v)), w = 420, h = 22;
const esc = s => String(s).replaceAll('&', '&amp;').replaceAll('<', '&lt;');
`<svg viewBox="0 0 760 ${rows.length * h + 6}" width="760" height="${rows.length * h + 6}">` +
rows.map((r, i) => `<g transform="translate(0,${i * h})"><text x="0" y="14">${esc(r.name)}</text>` +
  `<rect class="bar${i === 0 ? ' hot' : ''}" x="230" y="4" width="${Math.round(r.v * w / top)}" height="14"/>` +
  `<text class="val" x="${Math.round(r.v * w / top) + 236}" y="14">${Math.floor(r.v / 60)}m ${String(r.v % 60).padStart(2, '0')}s</text></g>`).join('') +
`</svg>`
$js$) AS svg;
-- ctx: {jobs_svg: (SELECT svg FROM chart_jobs)}   template: <div class="chart">{{ jobs_svg }}</div>
```

The SVG uses classes (`bar`, `hot`, `val`), not colours, so the page's CSS tokens — and its
dark mode — style it. Escape label text in the JS (`replaceAll`, not a regex).

**miniplot** second: `bar_chart / line_chart / area_chart / scatter_chart(labels, values, title[, 'file.html'])`
(and `scatter_3d_chart`) writes a **stock Plotly page** that loads `cdn.plot.ly` and returns
the file path. Its default look is Plotly's, not the page's: restyle it to the page's tokens
or don't use it. It is the right reach for an interactive chart a static SVG cannot be.

**tera-loop SVG** last: precompute `px` in a page view and let the template emit
`<rect class="bar" width="{{ r.px }}">` inside `{% for %}` — acceptable when a chart is one
row of bars and quickjs would add nothing.

## 4. tera, verified 2026-09-22 (DuckDB 1.5.5)

| Rule | Why |
|---|---|
| Precompute in SQL: `printf('%dm %02ds', s // 60, s % 60) AS txt`, `(v * 420 // max_v) AS px` | tera has no `//`; `a / 12 \| round` fails to parse. Keep the template dumb: pixels, labels and text arrive finished |
| Don't use the `escape` filter on struct-derived values | it failed at render on them; escape in SQL or in the quickjs chart, render with `autoescape := false` |
| `{{ loop.index0 }}`, `{{ list \| length }}`, `{{ s \| truncate(length=48) }}`, `{{ s \| replace(from="a", to="b") }}`, `{{ s \| split(pat="/") \| last }}`, `{{ x \| default(value="…") }}` | the filters that work; `jobs.0.name` indexes a list |
| Never alias a column or a view with an existing table's name (`runs`, `tests`, `jobs`) | it binds to the table's struct: `+(STRUCT…)` / `len(STRUCT…)` errors that look like nonsense |
| `"commit".sha` | `commit` is a keyword in a struct path |
| `gh api --paginate` → `format := 'unstructured'`, then `unnest(json) AS t(b)` | it prints one array per page, concatenated |
| `COPY … (FORMAT csv, HEADER false, QUOTE '', ESCAPE '')` | writes the rendered string byte for byte; `FORMAT markdown` is for tables, not pages |

## 5. The page — granica memo style

Self-contained HTML, one file, one column. Modelled on `takehome-granica:analysis/report.html`
(memo) and `northwind.html` (tiles).

- Google Fonts `<link>` for IBM Plex Sans + Mono; everything else inline.
- `:root` tokens (`--bg --surface --surface-2 --ink --ink-soft --ink-faint --line --line-strong
  --bar --bar-soft --bar-hot --accent`) with the dark set repeated under `@media (prefers-color-scheme: dark)`
  guarded by `:root:not([data-theme="light"])` and again under `:root[data-theme="dark"]`.
- `.page{max-width:760px–820px}`; `header.doc-head` = mono uppercase `.kicker` over an `h1`,
  2px ink rule under it; a one-paragraph `.subhead` lede; `h2` sections split by a hairline.

The three blocks every page leads with, in this order:

**The Verdict — amber.** One sentence that is the answer, one paragraph of the numbers behind it.

```css
--accent:#c98a2b;            /* amber; dark: #e0a458 */
.verdict{background:var(--surface);border:1px solid var(--line);border-left:3px solid var(--accent);
         border-radius:2px;padding:1.15rem 1.35rem;margin:0 0 1.5rem}
.verdict-label{font-family:"IBM Plex Mono",monospace;font-size:.7rem;letter-spacing:.12em;
               text-transform:uppercase;color:var(--accent);margin-bottom:.5rem}
.verdict-line{font-size:1.06rem;line-height:1.45;margin:0 0 .6rem;text-wrap:balance}
.verdict-sub{font-size:.9rem;line-height:1.6;color:var(--ink-soft);margin:0}
```

(`report.html` references `--rule` and `--accent` without defining them — define both.)

**"What we ran" tiles.** A grid of cards, one per input or measured quantity: mono uppercase
label, one big mono number, one line of meta.

```css
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(10rem,1fr));gap:.8rem;margin:1rem 0}
.tile{background:var(--surface);border:1px solid var(--line);border-radius:8px;padding:.85rem 1rem}
.tile .label{font-family:"IBM Plex Mono",monospace;font-size:.7rem;letter-spacing:.1em;text-transform:uppercase;color:var(--ink-faint)}
.tile .big{font-family:"IBM Plex Mono",monospace;font-size:1.35rem;font-weight:600;font-variant-numeric:tabular-nums}
.tile .meta{font-size:.75rem;color:var(--ink-faint)}
.tile.win{border-color:var(--bar);box-shadow:0 0 0 1px var(--bar)}
```

**The scoreboard card.** The one table that ranks the options: a bordered, rounded surface
(`.table-wrap{overflow-x:auto;border:1px solid var(--line);border-radius:8px}`), uppercase
`th` on `--surface-2`, right-aligned `tabular-nums`, and the pick row highlighted
(`tr.pick td{background:var(--bar-soft);font-weight:600}`) with a `.tag` in its last cell.

Then the sections, each chart in a `.chart` surface, and a `footer` naming the `.sql` that
generated the page and where `raw/` is.

## 6. CI pages in particular

The CI slowness and PR-review pages are the worked examples of all of this:
`~/inframe/internal/ci/duckdb/slow.sql` → `slow.html` and `review.sql` → `review.html`.
Where their data comes from (`gh` through shellfs, the Actions log zip through duck_hunt) is
`/duckstack:ci-timing`; the log readers are `/duckstack:duck-hunt`.

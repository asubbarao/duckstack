---
name: one-pager
description: >
  Turn a DuckDB analysis into a shareable, self-contained HTML one-pager: one .sql file that
  fetches through shellfs, lands raw responses under raw/, builds views, and renders the page
  with the `tera` community extension (tera_render) — inline SVG bar charts, no JS, no .sh, no
  Python. Use when asked for "something to share", "a one pager", "a report page", "charts of
  X", or when a dash/GUI would be the wrong deliverable. Exemplars: takehome-granica
  analysis/report.html, quackapi bench/report.sql, ~/Desktop/inframe-ci-timing/slow.sql.
argument-hint: "<what the page answers> [data source]"
allowed-tools: Bash
---

Read `/duckstack:duck` first; its process rules (reader first, keep the row, `array_agg` +
`len` over `count`, no macros, one layer at a time) apply here unchanged. This skill only adds
the last step: rendering.

## The shape of the file

```
x.sql
├── INSTALL/LOAD  shellfs, tera (+ zipfs, duck_hunt, duck_tails as needed)
├── 1. fetch      read_json('cmd | tee raw/<name>-$(date -u +%Y%m%dT%H%M%SZ).json |')
├── 2. raw views  read_json('raw/<name>-*.json', filename := true)
├── 3. tables     newest copy per key: QUALIFY row_number() OVER (PARTITION BY key ORDER BY filename DESC) = 1
├── 4. page views everything the template prints, precomputed (text, pixels)
└── 5. render     SET VARIABLE ctx = {…}::JSON;  COPY (SELECT tera_render($tpl$…$tpl$, getvariable('ctx'), autoescape := false)) TO 'x.html' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '')
```

Run: `duckdb :memory: -c ".read x.sql" && open x.html`. Re-running re-fetches and appends a
new raw file; nothing is overwritten, so the page is reproducible from `raw/` offline.

## Rendering, verified 2026-09-22 (tera extension, DuckDB 1.5.5)

```sql
-- tera_render(template VARCHAR, context JSON, autoescape := true)
SET VARIABLE ctx = {
  generated: strftime(now(), '%Y-%m-%d %H:%M UTC'),
  rows: (SELECT list(r) FROM page_rows r)          -- a list of structs → tera loops over it
}::JSON;
```

| Rule | Why |
|---|---|
| Precompute in SQL: `printf('%dm %02ds', s // 60, s % 60) AS txt`, `(v * 420 // max_v) AS px` | tera has no `//`; `a / 12 \| round` fails to parse; keep the template dumb |
| Don't use the `escape` filter on these values | it failed at render on struct-derived strings; the page is private, autoescape is off |
| `{{ loop.index0 }}`, `{{ list \| length }}`, `{{ s \| truncate(length=48) }}`, `{{ s \| replace(from="a", to="b") }}`, `{{ s \| split(pat="/") \| last }}` | the tera filters that work; `jobs.0.name` indexes a list |
| Never alias a column with an existing table's name (`runs`, `tests`, `jobs`) | it binds to the table's struct: `+(STRUCT…)` / `len(STRUCT…)` errors that look like nonsense |
| `"commit".sha` | `commit` is a keyword in a struct path |
| `gh api --paginate` → `format := 'unstructured'`, then `unnest(json) AS t(b)` | it prints one array per page, concatenated |

## The page

Self-contained HTML, one file, no external JS. Modelled on
`asubbarao/takehome-granica:analysis/report.html` (read it with duck_tails, not curl):

- `<link>` to Google Fonts IBM Plex Sans + Mono; everything else inline.
- `:root` tokens (`--bg --surface --ink --ink-soft --line --bar --bar-hot --rec-bg …`) with a
  `@media (prefers-color-scheme: dark)` block guarded by `:root:not([data-theme="light"])`
  and a `:root[data-theme="dark"]` block.
- One column, `max-width: 820px`; `header.doc-head` with a mono `.kicker` line and an `h1`;
  `h2` sections separated by a hairline; a dark `.rec` block for the one finding that matters.
- Charts are horizontal bars: a tera loop emitting `<g transform="translate(0,{{ loop.index0 * 22 }})">` with a
  label `<text>`, a `<rect class="bar" width="{{ r.px }}">`, and a `<text class="val">`.
  `viewBox="0 0 760 {{ rows | length * 22 + 6 }}"`. Colour the long pole `class="bar hot"`.
- Tables for the rest: `.wrap{overflow-x:auto}` around them, `tabular-nums` on numbers.

## CI slowness in particular (duck_hunt)

pytest-xdist prints no durations, but every Actions log line is timestamped:

```sql
LOAD zipfs; LOAD duck_hunt;
CREATE TABLE tests AS
SELECT log_file, right(message, 28)::TIMESTAMP AS ts, error_code AS gw, severity AS outcome,
       ref_file AS file, test_name,
       date_diff('millisecond', lag(ts) OVER (PARTITION BY log_file, gw ORDER BY ts), ts) AS ms
FROM read_duck_hunt_log('zip://raw/run-<id>.zip/*Backend Tests Shard*.txt',
  'regexp:(?P<message>\S+Z) \[(?P<code>gw\d+)\] \[\s*\d+%\] (?P<severity>PASSED|FAILED|SKIPPED|ERROR|XFAIL|XPASS) (?P<file>[^:\s]+)::(?P<test_name>\S+)');
```

`right(…, 28)` drops the BOM on the first line. The gap includes the test's fixtures, which is
the number a human cares about. Job and step wall times come from `gh run view <id> --json
databaseId,jobs` (steps carry `startedAt`/`completedAt`). Tests that land on an exact round
number of seconds (5.0, 10.0) are timeouts, not work — list them as the cheapest wins.

Worked example: `~/Desktop/inframe-ci-timing/slow.sql` → `slow.html`.

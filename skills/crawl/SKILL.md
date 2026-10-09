---
name: crawl
description: >
  Pages as tables. curl through shellfs fetches, lake.agents.ext_fetch keeps the raw page, webbed parses;
  the logged-in Chrome (duckdb-chrome-bridge) for SPAs and authenticated pages. Use when the user says
  crawl, scrape, fetch these URLs, hit these links, get the page, read the docs at, or gives URLs to read.
  Lands the raw response first, parses by the capability ladder — never regex, never an error page as a
  seed, never chrome_open to read.
argument-hint: "<url> [url ...] [--shape map|rounds|walk|crossjoin|staged] [--chrome]"
allowed-tools: mcp__dev__query, mcp__dev__execute
---

You are fetching web pages into tables. Read `/duckstack:duck` first. A scraper is not a
program; it is two decisions — **crawl topology** (how the URL space is discovered) and
**section delimiter** (what bounds the datum on a page). The deliverable is SQL on dev whose
`SELECT` is a tabular grid of the pages.

`crawler` has no DuckDB 1.5.6 build (404 on community-extensions, 2026-10-09), so `crawl()`,
`crawl_url()`, `sitemap()` and `css_select()` do not run on dev. Everything below runs today.

## Working method

**curl through shellfs** fetches, **webbed** parses HTML, **JSONata or QuickJS** transform,
**Tera** renders. Use only the parts that simplify the task. `urlpattern` and `netquack` for URL
operations. Search `agents.ext_docs` for capabilities before checking live signatures.

Keep raw responses, source URLs and fetch times. Parse stored content again instead of fetching
it again; refresh only missing or stale pages. Keep missing values NULL; `nullif(value, '')` is fine.

Expect to iterate. Start with one page, inspect actual rows, then widen. Verify a rerun fetches
nothing. A first query or an HTTP 200 is not completion.

## Step 1 — Land the raw pages

`lake.agents.ext_fetch` is the page log on dev: `url`, `fetched_at`, `response` JSON
`{status, body}`. Every crawl lands there; `agents.ext_page` is the newest good fetch per url.
No new table per crawl.

A fixed seed set is literal statements, one per url (verified 2026-10-09, 408,266 chars landed):

```sql
INSERT INTO lake.agents.ext_fetch BY NAME
SELECT 'https://github.com/Angelerator/Sazgar' AS url, now() AS fetched_at,
       json_object('status', 200, 'body', content) AS response
FROM read_text('curl -sSL --fail --max-time 30 https://github.com/Angelerator/Sazgar |');
```

`--fail` makes a non-2xx exit non-zero, so the reader errors and no row lands; the url stays
due and is retried. `--max-time` bounds every fetch. Add `-A '<agent>'`, `-H` or cookies as
the site needs; they are curl flags, not a framework.

URLs held in a column are self-dispatched, one literal statement per row, the HTTP status as
the receipt (this is the hourly catalog job in `server/setup.sql`):

```sql
WITH due AS (
    SELECT url FROM agents.ext_stale ORDER BY url LIMIT 90
)
SELECT url, http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', tera_render($t$
INSERT INTO lake.agents.ext_fetch BY NAME
SELECT '{{ url }}' AS url, now() AS fetched_at, json_object('status', 200, 'body', content) AS response
FROM read_text('curl -sSL --fail --max-time 30 {{ url }} |')
$t$, json_object('url', url), autoescape := false))) ->> '$.status' AS status
FROM due;
```

Appends into one DuckLake table do not conflict; concurrent `MERGE`/`UPDATE` of the same table do
(422), so land rows, never upsert.

There is no "next round" code. The url set is a view: seeds, plus the same-site links of the pages
already landed, anti-joined against `agents.ext_page` (that is what `agents.ext_url` and
`agents.ext_stale` are for the catalog). The hourly cron fetches whatever that view says is due,
so a crawl grows one round per tick until the view is empty.

## Step 2 — Look before parsing

```sql
SELECT url, fetched_at, length(response ->> 'body') AS chars, left(response ->> 'body', 50) AS head
FROM agents.ext_page WHERE starts_with(url, 'https://<site>/') ORDER BY url;
```

Never return a page body to the conversation: lengths, heads, counts, and bounded block or link rows.

## Step 3 — Parse, one layer at a time, by the ladder

1. **Did the page publish the datum as data?** JSON-LD (`<script type="application/ld+json">`),
   a search index JSON, a raw markdown source on GitHub → read it by JSON path, no selector.
2. **Blocks**: `html_to_duck_blocks(body::HTML)` → headings, paragraphs, code, tables in page
   order; `duck_blocks_to_md` renders them. `agents.ext_doc_sections` is this applied to every
   readthedocs page on dev.
3. **Links**: `html_extract_links(body::HTML)` → `STRUCT(text, href, title, line_number)[]`,
   expanded once with `CROSS JOIN UNNEST`.
4. **Tables**: `html_extract_tables(body::HTML)`; never walk `<tr>/<td>`.
5. **One region**: `html_extract_text(body::HTML, '<xpath>')` → the matching nodes' text as a
   list; XPath for axes, text predicates, `last()`, `not()`.

```sql
WITH page AS (
    SELECT url, (response ->> 'body')::HTML AS html FROM agents.ext_page WHERE url = 'https://<site>/<page>'
)
SELECT url, b.element_order AS n, b.element_type AS type, left(trim(b.content), 120) AS text
FROM page CROSS JOIN UNNEST(html_to_duck_blocks(html)) AS t(b)
WHERE b.kind = 'block' ORDER BY n;
```

URLs are strings: `url_resolve`, `url_origin`, `urlpattern_test`, `starts_with`, not `LIKE`, not regex.

## The shape catalog — pick before writing

| The site looks like… | Shape | Rounds |
|---|---|---|
| one page lists every target (TOC, index, API listing) | **map** — parse the authored map, one fan-out | 1 |
| content is K known hops away (listing → descriptor → content) | **rounds** — each round one dispatch of the links the previous round found; never `WITH RECURSIVE` | K |
| no map, unknown depth | **walk** — same-site links of landed pages, bounded by `LIMIT` per round (the readthedocs job in `server/` is one) | n |
| pages are table-carriers keyed by an entity; the ask is relational | **crossjoin** — `html_extract_tables` per entity, typed join the site never renders | 1 + join |
| it should refresh on its own | **staged** — a `cron()` line in `server/setup.sql` over a stale view; run 2 fetches 0 pages | — |
| any of the above behind auth / an SPA | `--chrome` (below), or curl with the session cookie | — |

## `--chrome` — the page needs the user's session or a rendered DOM

Use **duckdb-chrome-bridge** (`~/Documents/Codex/2026-09-16/how-to-integrate-connect-my-personal-2/work/duckdb-chrome-bridge`,
`git@github-asubbarao:asubbarao/duckdb-chrome-bridge.git`): the Chrome already running is a
set of relations via osascript over `shellfs` — no CDP, no fresh profile, every logged-in
session already there. Load its `sql/browser.sql` + `sql/harvest.sql` into the client as its
README says (that process needs the macOS Automation → Chrome grant and "Allow JavaScript from
Apple Events"). Then the six verbs, in order:

```sql
FROM browser_health;                                          -- ok MUST be true; NULL = osascript never answered
FROM chrome_target('https://<site>/<prefix>');                -- LOCATE: 0 rows = wrong prefix, >1 = ambiguous
SELECT chrome_settle('https://<site>/<prefix>', '<probe js>', 10, 1.0);     -- readiness as a value
SELECT chrome_exhaust('https://<site>/<prefix>', '<probe js>', 30, 4, 1.5); -- infinite scroll, on entity count
FROM chrome_routes('https://<site>/<prefix>');                -- which href segment is the entity
FROM chrome_entities('https://<site>/<prefix>', '<segment>'); -- (href, title) rows
SELECT chrome_at('https://<site>/<prefix>', 'outer_html');    -- RAW DOM, then webbed as above
```

Rules the repo learned the hard way: **never `chrome_open` to read** (stomps the tab);
coordinates typed by hand return the wrong tab's DOM with no error — `chrome_at` matches by
URL prefix inside the osascript; a background tab does not lazy-load; `chrome_capture` lands
the DOM once so a wrong extractor costs a query, not a re-scrape. Chrome hands over raw markup
only; parsing is the same ladder as above.

## Step 5 — Read it out

Bounded slices into the conversation; anything bigger stays on dev and you say where.

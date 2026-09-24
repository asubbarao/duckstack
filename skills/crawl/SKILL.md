---
name: crawl
description: >
  Pages as tables. crawler × webbed on the dev quack for anything a plain HTTP fetch can reach;
  the logged-in Chrome (duckdb-chrome-bridge) for SPAs and authenticated pages. Use when the
  user says crawl, scrape, fetch these URLs, hit these links, get the page, read the docs at,
  or gives URLs to read. States every crawl() parameter, lands the raw response first, parses
  by the capability ladder — never regex, never uncorrelated laterals, never an error page as
  a seed, never chrome_open to read.
argument-hint: "<url> [url ...] [--name raw_table] [--shape map|rounds|walk|crossjoin|staged] [--chrome]"
allowed-tools: Bash
---

You are fetching web pages into tables. Read `/duckstack:duck` first. A scraper is not a
program; it is two decisions — **crawl topology** (how the URL space is discovered) and
**section delimiter** (what bounds the datum on a page) — answered with crawler and webbed used
raw. The deliverable is one `.sql` artifact whose `SELECT *` is a tabular grid of the pages.

## Working method

Use **crawler** to fetch, **webbed** to parse HTML, **JSONata or QuickJS** for transformations,
**json_schema** for validation, and **Tera** for rendering. Use only the parts that simplify
the task. Use urlpattern for URL operations and encoding, ScalarFS to expose stored content
to readers, and separate `.tera` files when a template helps. Search `agents.ext_catalog`
or `agents.ext_docs` for capabilities and documented parameters before checking live signatures.

Keep raw responses, source URLs, fetch times, extracted links, dispatch receipts and errors
alongside derived columns. Parse stored content again instead of fetching it again; refresh
only missing or stale sources. An existing authoritative raw source needs no duplicate copy.
Keep missing values NULL. `nullif(value, '')` is fine; replacing NULL with an empty string is
reserved for a final ML input that explicitly requires it. Alternate real sources can use COALESCE.

Self-dispatch is the default composition: source rows → complete SQL per row → scalar posts
to the explicitly selected existing service → receipt array → CROSS JOIN UNNEST. Each dispatched
statement binds its own literal arguments, allowing table functions to consume values from an
outer row without requiring correlated table-function support. Preserve the generated SQL and
inner errors: this handles outer binding restrictions, not invalid SQL or unsupported functions.

Expect to iterate. Start with one representative extension or page, inspect actual rows and
raw/parsed content, then refine the query. Verify required information survives parsing before
expanding the crawl. Verify a fresh rerun skips fetches. Save the useful pattern and any observed
version limitations in the reusable guidance; do not treat a first query or HTTP 200 as completion.
Keep the pipeline readable, with intermediate columns available and a compact final projection.
Use ordinary SQL for the pipeline; reserve macros for genuine reusable primitives.

Input: `$@` — URLs; `--name` for the raw table (default `raw_<slug>`); `--shape` if the
topology is known; `--chrome` when the page needs the user's session or a rendered SPA.

## Where it runs

Use the explicitly selected existing service; do not infer a port from this guide. Install and
load needed community extensions there. On the MCP/9495 path, use `agent_crawl(urls)` for seeds
as required by the workspace instructions. The older direct-Quack example below applies only
when that endpoint has been explicitly selected; replace its address with the selected address.
Keep persistent tables on that service, with `:memory:` acting as a client/orchestrator.

```sql
-- crawl_<name>.sql — crawler × webbed. QUACK_TOKEN="$(cat ~/.duck/token)" duckdb :memory: -f crawl_<name>.sql
LOAD quack;
ATTACH 'quack:localhost:9494' AS dev (TYPE quack, TOKEN getenv('QUACK_TOKEN'));
FROM dev.query($$ ... one statement ... $$);
FROM dev.query($$ ... next statement ... $$);
```

Crawler settings (`crawler_default_delay`, `crawler_timeout_ms`, `crawler_user_agent`, …) are
GLOBAL and **locked on dev** — pass the per-call parameters instead. `--local` (client-side
`LOAD crawler; LOAD webbed;`) only when the result must not persist.

## The registered surface (verified on dev, crawler 7725ede, DuckDB 1.5.5)

`crawl` takes the URL list plus **13 named parameters**. State all of them, every time, with
the comment block — a crawl that does not say its timeout, workers, batch size, delay,
link-following, depth, cache and result limit did not happen.

```sql
-- crawl(urls VARCHAR[], cache := true, cache_ttl := 24 /*h*/, timeout := 30 /*s*/,
--       delay := 1000 /*ms*/, workers := 4, batch_size := 10, respect_robots := true,
--       follow := '' /*no link following*/, max_depth := 1, state_table := '',
--       user_agent := crawler_user_agent, max_results := -1, extract := [])
--   -> url, status, content_type, html STRUCT(document, js, opengraph, schema, readability),
--      error, extract, response_time_ms, depth
--   cache := false, ALWAYS. The extension default is true, and a cached call creates
--   __crawler_cache with a computed DEFAULT, which breaks every quack ATTACH on 1.5.5
--   and is a table nobody wants. The landed table IS the cache; fetched_at says when.
--   state_table := 'x': crawler's own incremental machine — a second run fetches only new URLs.
```

| function | parameters | note |
|---|---|---|
| `crawl_url(url, extract := [], cache_ttl, max_results, cache, timeout, user_agent)` | lateral form — **only** `FROM rel CROSS JOIN LATERAL crawl_url(rel.url, …)` |
| `crawl_stream(urls, user_agent, crawl_delay, timeout, respect_robots_txt)` | streaming variant |
| `sitemap(url, filter, timeout, user_agent, discover, max_depth, recursive)` | XML sitemap → rows; often an empty `<urlset/>` — check |
| `read_html(...)` | registered by **both** crawler and webbed, resolves by arity: named parameters only |
| `html_extract_links(doc)`, `html_extract_text(doc, xpath)`, `html_extract_tables(doc)`, `xml_to_json`, `::HTML` | webbed — parse what you hold |
| `css_select(col0, col1, col2)`, `jq(col0, col1[, col2])`, `htmlpath(col0, col1)` | crawler CSS on raw strings — `css_select` is the known-shape reach, see "CSS selectors" below |

`CRAWL … INTO` statement syntax is **not** registered in this build (syntax error, server and
CLI alike). This is a version-specific observation. Start with the extension catalog, then
check the selected service's actual signatures and execute a small proof when docs disagree.

## The capability ladder — the first "yes" decides (conduit `parsing-with-crawler-and-webbed.md`)

1. Need to fetch? → crawler, always first (webbed has no HTTP).
2. **Did the page publish the datum as data?** `html.hydration` (SPA state), `html.schema`
   (JSON-LD), `html.readability` (article text), a search index JSON, a raw markdown source
   on GitHub → read it by JSON path, **no selector at all**. The cleanest scrape is the one you
   don't do.
3. XML / namespaces / building a payload → webbed.
4. Rendered HTML you must select → CSS (`tag.class #id`) until it cannot express the query;
   XPath exactly when you need an axis, a text predicate, `last()`, `not()`, `local-name()`.

Tables: `html_extract_tables(doc)` — never walk `<tr>/<td>`. URLs are strings — literal
`string_split` / `starts_with` / `netquack`, not `LIKE`, not regex.

## CSS selectors: css_select

Verified 2026-09-22 in `duckdb :memory:` (DuckDB 1.5.5, crawler 7725ede). **crawler**
registers it, not webbed: with `autoload_known_extensions = false`, `LOAD crawler` alone lists
`css_select` in `duckdb_functions()` and `LOAD webbed` alone does not.

```sql
-- css_select(html VARCHAR, selector VARCHAR, mode VARCHAR) -> VARCHAR
--   all three required (a two-argument call is a Binder Error); first match only
--   mode 'text'        -> the match's text, descendants included, outer whitespace trimmed
--   mode 'html'        -> the match's outer HTML (attributes re-serialised in sorted order)
--   mode 'attr:<name>' -> that attribute of the match
SELECT css_select('<div class="a"><p id="p1">hi <b>there</b></p></div>', 'div.a p', 'text');     -- hi there
SELECT css_select('<div class="a"><p id="p1">hi <b>there</b></p></div>', 'div.a p', 'html');     -- <p id="p1">hi <b>there</b></p>
SELECT css_select('<a class="l" href="/x">one</a><a href="/y">two</a>', 'a', 'attr:href');        -- /x
SELECT css_select(page.doc, 'li:nth-child(2)', 'text') FROM page;                                 -- a column works, per row
```

Exactly those three modes exist. Every other mode string tried — `all`, `list`, `count`,
`inner`, `outer`, `inner_html`, `outer_html`, `innerHTML`, `outerHTML`, `json`, `texts`,
`first`, `attr`, `href`, `''`, and `HTML` (modes are case-sensitive) — is **silently treated as
`text`**; `attr:` with no name returns `''`. The quiet cases: no match, a missing attribute,
and an invalid selector (`'p['`) all return `''`, not NULL — only a NULL argument gives NULL.
So an empty result does not mean the element is empty; check with `'html'` before trusting it.
Passing webbed's `::HTML` works (implicit cast to VARCHAR).

Where it sits: **ingest whole first** when the shape is unknown — the Step 2 look, `read_html`
/ `html.readability` / `html.schema`, `DESCRIBE`. Once the page's shape is known and the
datum is one element, `css_select` with a CSS selector is the reach, **before** any
`html_extract_text(doc, xpath)` or `html_extract_*` path; XPath only when CSS cannot express
it (axes, text predicates). It returns one match, so it is for a known single element per
page, not for lists — lists are `html_extract_links` / `html_extract_tables`. When you want
that one element whole rather than one mode of it, `jq(html, selector)` returns the first match
as `STRUCT(text VARCHAR, html VARCHAR, attr MAP(VARCHAR, VARCHAR))` (verified; its `html` is
the inner HTML, and it is NULL on no match). The selector string belongs in a column of an upstream
relation, not hand-written per SELECT item.

## The shape catalog (conduit `scraping.md`) — pick before writing

| The site looks like… | Shape | Rounds |
|---|---|---|
| one page lists every target (TOC, index, API listing) | **map** — parse the authored map, one fan-out | 1 |
| content is K known hops away (listing → descriptor → content) | **rounds** — each round one CTE / one landed table; the base case yields content not URLs; never `WITH RECURSIVE` | K |
| no map, unknown depth, or a sitemap exists | **walk** — `sitemap()`, or crawler's `follow`/`max_depth`/`state_table`, bounded | n |
| pages are table-carriers keyed by an entity; the ask is relational | **crossjoin** — `html_extract_tables` per entity, typed join the site never renders | 1 + join |
| it should live on the server (cron, incremental state) | **staged** — the artifact's tables + `state_table` + a `cron()` line; run 2 fetches 0 pages | — |
| any of the above behind auth / an SPA | `--chrome` (below), or `CREATE SECRET (TYPE HTTP, EXTRA_HTTP_HEADERS …)` on the client | — |

## Step 1 — Land the raw pages (one statement, every column, nothing dropped)

```sql
FROM quack_query('quack:localhost:9494', $$
-- <what this is for>. Every column crawl() returns, nothing dropped.
-- crawl(urls VARCHAR[], cache := true, cache_ttl := 24, timeout := 30, delay := 1000, workers := 4,
--       batch_size := 10, respect_robots := true, follow := '', max_depth := 1, state_table := '',
--       user_agent := crawler_user_agent, max_results := -1, extract := [])
CREATE OR REPLACE TABLE raw_<name> AS
SELECT now() AS fetched_at, *
FROM crawl(
    ['<url1>', '<url2>'],
    "extract"      := []::VARCHAR[],
    state_table    := '',
    user_agent     := 'InFrame <purpose>/1.0',
    timeout        := 30,
    workers        := 2,
    batch_size     := <n urls>,
    delay          := 1000,
    respect_robots := true,
    follow         := '',
    max_depth      := 1,
    cache          := false,
    cache_ttl      := 24,
    max_results    := <n urls>
)
$$, token := getenv('QUACK_TOKEN'));
```

Seeds only on the first pass — never `follow`/`max_depth > 1` until the raw table has been
looked at; `max_results` = seed count so it cannot run away.

## Step 2 — Look before parsing

```sql
FROM dev.query($$
SELECT url, status, content_type, len(html.document) AS doc_chars,
       len(html.readability) AS readability_chars, map_keys(html.schema) AS schema_types, error, depth
FROM raw_<name> ORDER BY url
$$);
```

A non-200, a NULL document, or an `error` is a row to **keep and report**, never a seed.
Everything downstream starts from `WHERE status = 200 AND error IS NULL`. `schema_types` and
`html.readability` tell you which rung of the ladder you are on.

## Step 3 — Parse, one layer at a time, by the ladder

```sql
FROM dev.query($$
-- layer 1: what the page already published, typed, by name
CREATE OR REPLACE TABLE <name>_l1 AS
SELECT fetched_at, url, status,
       html.readability::JSON  AS readability,
       readability->>'title'   AS title,
       readability->>'text_content' AS text,
       html.document::HTML     AS doc              -- webbed's type, for the next layer
FROM raw_<name>
WHERE status = 200 AND error IS NULL
$$);
```

Then `DESCRIBE`, then the next column: `html_extract_links(doc)` → `(text, href)` rows,
`html_extract_tables(doc)` → `(table_index, row_index, columns)`, `html_extract_text(doc, xpath)`
for a section bounded by a heading or a named anchor (`//text()[preceding::a[@name][1][@name="…"]]`
is the conduit idiom). Assembly is `array_agg(… ORDER BY …)` → `array_to_string`, or `tera_render`.

## Step 4 — The next round, incremental

The next hop's URLs are a column of the previous table; the fetch is correlated or fed by a
variable; 3–5 first:

```sql
-- correlated lateral (per-row fetch): the ONLY shape for crawl_url
FROM dev.query($$
CREATE OR REPLACE TABLE raw_<name>_r2 AS
-- crawl_url(url, extract := [], cache_ttl := 24, max_results := -1, cache := true, timeout := 30, user_agent := ...)
SELECT now() AS fetched_at, l.url AS parent, c.*
FROM (SELECT url, href FROM <name>_links WHERE starts_with(href, 'https://') ORDER BY href LIMIT 5) l
CROSS JOIN LATERAL crawl_url(l.href, "extract" := []::VARCHAR[], cache := false, cache_ttl := 24,
                             max_results := 1, timeout := 30, user_agent := 'InFrame <purpose>/1.0') AS c
$$);

-- or the list rides in a variable and crawl() runs once with state_table (the staged shape)
FROM dev.query($$
SET VARIABLE urls = (SELECT list(href) FROM <name>_links);
CREATE TABLE IF NOT EXISTS <name>_pages AS SELECT now() AS fetched_at, * FROM crawl(getvariable('urls'), ... all 13 ..., state_table := '<name>_state') WHERE false;
INSERT INTO <name>_pages BY NAME
SELECT now() AS fetched_at, * FROM crawl(getvariable('urls'), ... all 13 ..., state_table := '<name>_state') WHERE status = 200
$$);
```

`crawl_url` without the `CROSS JOIN LATERAL … (rel.col)` correlation is the exact shape that
caused the incident behind this rule. Do not write it.

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

Bounded slices into the conversation; anything bigger stays a table on dev and you say where.
A document to disk is `COPY (SELECT …) TO '<path>' (FORMAT csv, HEADER false, QUOTE '')` from
the artifact — the server writes its own disk.

## Verification (trailing comments in the artifact)

```sql
--   FROM dev.query($$SELECT url, status, error FROM raw_<name> WHERE status <> 200 OR error IS NOT NULL$$);  -- empty or explained
--   FROM dev.query($$SELECT count(*) FROM raw_<name>$$);                                                    -- = seed count
```

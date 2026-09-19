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

Input: `$@` — URLs; `--name` for the raw table (default `raw_<slug>`); `--shape` if the
topology is known; `--chrome` when the page needs the user's session or a rendered SPA.

## Where it runs

On **dev** (`quack:localhost:9494`), where `crawler`, `webbed`, `netquack`, `urlpattern`,
`markdown` are loaded and the table is then queryable by every client and the agent door.
The artifact:

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
--   cache := false: the landed table IS the cache; fetched_at says when.
--   state_table := 'x': crawler's own incremental machine — a second run fetches only new URLs.
```

| function | parameters | note |
|---|---|---|
| `crawl_url(url, extract := [], cache_ttl, max_results, cache, timeout, user_agent)` | lateral form — **only** `FROM rel CROSS JOIN LATERAL crawl_url(rel.url, …)` |
| `crawl_stream(urls, user_agent, crawl_delay, timeout, respect_robots_txt)` | streaming variant |
| `sitemap(url, filter, timeout, user_agent, discover, max_depth, recursive)` | XML sitemap → rows; often an empty `<urlset/>` — check |
| `read_html(...)` | registered by **both** crawler and webbed, resolves by arity: named parameters only |
| `html_extract_links(doc)`, `html_extract_text(doc, xpath)`, `html_extract_tables(doc)`, `xml_to_json`, `::HTML` | webbed — parse what you hold |
| `jq`, `htmlpath`, `css_select` | crawler CSS on raw strings — prefer the typed cast + webbed |

`CRAWL … INTO` statement syntax is **not** registered in this build (syntax error, server and
CLI alike). The README documents a different codebase than the shipped build; `duckdb_functions()`
on dev wins.

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
FROM dev.query($$
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
$$);
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

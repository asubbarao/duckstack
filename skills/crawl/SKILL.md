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
operations. Search `agents.ext_catalog` for capabilities before checking live signatures.

Keep raw responses, source URLs and fetch times. Parse stored content again instead of fetching
it again; refresh only missing or stale pages. Keep missing values NULL; `nullif(value, '')` is fine.

Expect to iterate. Start with one page, inspect actual rows, then widen. Verify a rerun fetches
nothing. A first query or an HTTP 200 is not completion.

## Step 1 — Land the raw pages

`lake.agents.ext_fetch` is the page log on dev: `url`, `fetched_at`, `response` JSON
`{status, body}`. Every crawl lands there; the newest fetch per url is
`arg_max(response ->> 'body', fetched_at) … GROUP BY url`. No new table per crawl.

A fixed seed set is literal statements, one per url (verified 2026-10-09, 408,266 chars landed):

```sql
-- timeout 30 s; one worker; batch 1; no delay; no link following, depth 0; no cache; one page.
INSERT INTO lake.agents.ext_fetch BY NAME
SELECT 'https://github.com/Angelerator/Sazgar' AS url, now() AS fetched_at,
       json_object('status', 200, 'body', content) AS response
FROM read_text('curl -sSL --fail --max-time 30 https://github.com/Angelerator/Sazgar |');
```

`--fail` makes a non-2xx exit non-zero, so the reader errors and no row lands; the url stays
due and is retried. `--max-time` bounds every fetch. Add `-A '<agent>'`, `-H` or cookies as
the site needs; they are curl flags, not a framework. A 429 or 5xx is retried by curl itself:
`--retry 2 --retry-delay 1` (verified 2026-10-20: two retries logged, then the final 429).
Space requests with `sleep_ms(<ms>)`, not a shell sleep.

A public page with no session needs no curl at all: httpfs reads it, `read_text('<url>')`,
`read_json('<url>')` or webbed `read_html('<url>')`, and follows redirects, http→https included.
It throws on a 404, so a url column is self-dispatched to make each failure a receipt.

Every crawl states its limits, in a comment above the query: timeout, workers, batch size,
delay, link-following, depth, cache and result limits. An API error page is never a seed.

URLs held in a column are self-dispatched, one literal statement per row, the HTTP status as
the receipt ([references/crawl_rows.sql](references/crawl_rows.sql) is the same shape):

```sql
-- timeout 30 s per fetch; workers: one post per url, sent together; batch 90; no delay;
-- no link following, depth 0; cache: a url fetched in the last day is skipped; one page per url.
WITH seeds AS (
    SELECT unnest(['https://<site>/<page-a>', 'https://<site>/<page-b>']) AS url, now() AS fetched_at
), due AS (
    SELECT url, fetched_at FROM seeds
    ANTI JOIN (FROM lake.agents.ext_fetch WHERE fetched_at > now() - INTERVAL 1 DAY) AS recent USING (url)
    ORDER BY url LIMIT 90
), rendered AS (
    SELECT tera_render($tera$
INSERT INTO lake.agents.ext_fetch BY NAME
SELECT '{{ url }}' AS url, '{{ fetched_at }}'::TIMESTAMPTZ AS fetched_at, json_object('status', 200, 'body', content) AS response
FROM read_text($cmd$curl -sSL --fail --max-time 30 '{{ url }}' |$cmd$)
$tera$, due::JSON, autoescape := false) AS sql
    FROM due
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.status, receipt.body FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);
```

Appends into one DuckLake table do not conflict; concurrent `MERGE`/`UPDATE` of the same table do
(422), so land rows, never upsert.

There is no "next round" code. The url set is a query: seeds, plus the same-site links of the pages
already landed, anti-joined against recent fetches as above. Rerun it (or schedule it with
`cron()`) and a crawl grows one round per run until nothing is due. The only scheduled fetch on
dev today is the daily extension-catalog refresh in `server/ext_catalog.sql`.

## Sessions — cookies and logins

The jar is a relation, not a file. `curl -c -` prints the Netscape cookie jar to stdout and
`read_csv` reads it. The next request carries it as a `Cookie:` header in a self-dispatched curl
([references/cookie_jar.sql](references/cookie_jar.sql), verified 2026-10-20 against httpbin: the
jar gave `x=1` and `/cookies` echoed `{"x": "1"}`).

- **Log in:** `curl -sS -L -b '' -c - -o /dev/null [-d 'user=…&pass=…'] '<login url>' |`. The `-b ''`
  turns on the cookie engine so cookies set during the redirects are kept.
- **HttpOnly cookies are captured.** curl writes those lines with a `#HttpOnly_` prefix on the
  domain, so `comment = '#'` silently drops the session cookie. Read with `null_padding = true` and
  `WHERE name IS NOT NULL`, then `replace(domain, '#HttpOnly_', '')`. Verified on github.com/login:
  `_gh_sess` came back.
- **httpfs drops cookies set during a redirect**: `read_text('https://httpbin.org/cookies/set?x=1')`
  returns `{"cookies": {}}`. To carry a cookie you already have through httpfs, set a secret in your
  own `:memory:` client (never on dev):
  `CREATE SECRET (TYPE http, EXTRA_HTTP_HEADERS MAP {'Cookie': '<header>'}, SCOPE 'https://<site>')`.
- **Expired session:** a 401, or a redirect back to the login page, means log in again. The jar's
  `expires` column says when.
- **The Chrome bridge (`--chrome`)** is for a login that can't be scripted (MFA, captcha) or a
  session that already lives in Chrome. It is not needed just because a cookie is HttpOnly.
- **A form that needs a CSRF token:** GET the form, read the hidden `<input>` value and POST it
  back with the jar. `html_to_duck_blocks` drops `<input>`. The attribute XPath reads it:
  `html_extract_text(parse_html(body), '//input[@name=''authenticity_token'']/@value')`. On
  github.com/login that returned the 88-char token (2026-10-20).

## Step 2 — Look before parsing

```sql
SELECT url, fetched_at, response ->> 'status' AS status, length(response ->> 'body') AS chars,
       left(response ->> 'body', 50) AS head
FROM lake.agents.ext_fetch WHERE starts_with(url, 'https://<site>/') ORDER BY url, fetched_at LIMIT 7;
```

Never return a page body to the conversation: lengths, heads, counts, and bounded block or link rows.

## Step 3 — Parse, one layer at a time, by the ladder

1. **Did the page publish the datum as data?** JSON-LD (`<script type="application/ld+json">`),
   a search index JSON, a raw markdown source on GitHub → read it by JSON path, no selector.
2. **Blocks**: `html_to_duck_blocks(body::HTML)` → headings, paragraphs, code, tables in page
   order; `duck_blocks_to_md` renders them. The ext-catalog skill applies this to the readthedocs
   pages saved in `lake.agents.ext_fetch`.
3. **Links**: `html_extract_links(body::HTML)` → `STRUCT(text, href, title, line_number)[]`,
   expanded once with `CROSS JOIN UNNEST`.
4. **Tables**: `html_extract_tables(body::HTML)`; never walk `<tr>/<td>`.
5. **XPath, with the paths as rows.** Take the page's own element paths, filter them with a WHERE,
   and pass each one as a column. `html_extract_text(html, xpath)` takes a VARCHAR xpath, so no
   dispatch is needed. Use `parse_html(body)`: on 2026-10-20 `body::HTML` gave 0 attribute rows
   where `parse_html` gave 406. On nflbite this returned the 30 team names under
   `/html/body/div/div/header/div/div/nav/ul/li/div/a`:

```sql
WITH page AS (
    SELECT parse_html(content) AS html FROM read_text('https://<site>/<page>')
), document_xpaths AS (
    SELECT html, list_distinct(list_transform(xml_extract_attributes(html, '//*'), a -> a.element_path)) AS xpaths FROM page
)
SELECT xpath, html_extract_text(html, xpath) AS texts FROM document_xpaths CROSS JOIN UNNEST(xpaths) AS t(xpath);
```

   `xml_extract_attributes` lists only elements that have attributes. On github.com/login it
   returned 0 rows while `html_extract_text` worked, so check `len(xpaths)` before you rely on it.
   A hand-typed XPath for one known node is fine (`//input[@name='x']/@value`). A 40-line chain
   of them is the failure.

```sql
WITH page AS (
    SELECT url, arg_max(response ->> 'body', fetched_at)::HTML AS html
    FROM lake.agents.ext_fetch WHERE url = 'https://<site>/<page>' GROUP BY url
)
SELECT url, b.element_order AS n, b.element_type AS type, left(trim(b.content), 120) AS text
FROM page CROSS JOIN UNNEST(html_to_duck_blocks(html)) AS t(b)
WHERE b.kind = 'block' ORDER BY n;
```

URLs are strings: `url_resolve`, `url_origin`, `urlpattern_test`, `starts_with`, not `LIKE`, not regex.

Some sites ship tables inside HTML comments (`<!-- <table>… -->`), so every rung above misses them.
`string_split(body, '<!--')` and parse each fragment as HTML.

## The shape catalog — pick before writing

| The site looks like… | Shape | Rounds |
|---|---|---|
| one page lists every target (TOC, index, API listing) | **map** — parse the authored map, one fan-out | 1 |
| content is K known hops away (listing → descriptor → content) | **rounds** — each round one dispatch of the links the previous round found; never `WITH RECURSIVE` | K |
| no map, unknown depth | **walk** — same-site links of landed pages, bounded by `LIMIT` per round | n |
| pages are table-carriers keyed by an entity; the ask is relational | **crossjoin** — `html_extract_tables` per entity, typed join the site never renders | 1 + join |
| it should refresh on its own | **staged** — a `cron()` line in `server/setup.sql` over a stale view; run 2 fetches 0 pages | — |
| any of the above behind a login | curl with the cookie jar (Sessions, above); `--chrome` only if the login can't be scripted | — |
| an SPA (the data appears only after JavaScript runs) | `--chrome` (below) | — |

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

---
name: superhuman-docs
description: >
  Read a Superhuman Docs (ex-Coda) document and land it on the dev quack as tables. Two
  independent doors: the Superhuman Docs MCP connector (OAuth, reads page prose AND tables)
  and the `superhuman_docs` DuckDB community extension (API token, ATTACH, tables only).
  Use when given a docs.superhuman.com or coda.io URL, when asked to read an InFrame HUB
  page, or when deciding which door a Superhuman doc should come through.
argument-hint: "<docs.superhuman.com URL or doc-id> [--as <alias>]"
allowed-tools: Bash
---

A Superhuman Docs page is not a web page you crawl. It is a canvas of identified blocks plus
zero or more real tables, and there are two doors into it. They are not interchangeable and
neither is the `dev` MCP sidecar. Everything below was verified on this machine 2026-09-17
against DuckDB 1.5.5 osx_arm64, quack c154811, `superhuman_docs` 1d85c9e.

## 1. The two doors

| | MCP connector | `superhuman_docs` extension |
|---|---|---|
| What it is | remote OAuth MCP server, `https://docs.superhuman.com/apis/mcp`, a claude.ai connector | DuckDB community extension, `INSTALL superhuman_docs FROM community` |
| Auth | OAuth, user clicks Connect | API token only — `TOKEN`, `TOKEN_ENV`, or a `TYPE superhuman_docs` secret |
| Reads page prose | **yes** (`content_read`) | **no** |
| Reads doc tables | yes (`table_rows_read`) | yes, as `<alias>.main."<Table>"` |
| Writes back to the doc | yes (`page_update`, `table_rows_manage`) | yes (`INSERT`/`UPDATE`/`DELETE`) |
| Lives in SQL | no — it returns JSON to the agent | yes |

`duckdb_secret_types()` reports exactly one provider for this type: `config`. There is **no
OAuth provider**. Authorizing the connector therefore does *not* unblock the extension; they
need separate credentials. Do not tell the user otherwise.

The extension is a storage extension only: `duckdb_functions()` has **zero** entries for it.
`ATTACH` is the whole surface.

## 2. Which door to use

- **Page is prose** (a process doc, a spec, a runbook) → connector. The extension cannot see
  it at all; `main` will be empty or hold only the doc's grid tables.
- **Page is a table you want to query or join** → either. The extension is better if you will
  query it repeatedly; the connector is better for a one-shot read.
- **You need it as a table on dev** → connector for the read, then land it (§4). The extension
  cannot be reached from the dev server or from the MCP sidecar — see §3.

## 3. Why this cannot go in `setup.sql` or `mcp-setup.sql`

This is the question that keeps coming up. Three server-side reasons, all verified:

- **The MCP sidecar** (`~/.duck/mcp-setup.sql`) ends with `SET GLOBAL enable_external_access
  = false`, which is one-way, and `getenv()` is dead after that line. An extension that makes
  outbound HTTPS per query cannot work behind it. The quack `ATTACH` survives only because it
  is a socket opened *before* that line; do not assume an HTTP-backed catalog behaves the same.
  `allowed_directories` is also pinned to `~/inframe`, `~/.duck/ingest`, `~/.duck/logs`.
- **The dev server** (`~/.duck/setup.sql`) ends with `lock_configuration = true` and runs
  `autoinstall_known_extensions = false`. No `SET`, `INSTALL` or `LOAD` reaches it afterwards.
  Adding the extension means editing the source of truth
  (`~/duckdb-skills/server/setup.sql`), putting the token there as a secret, and a launchd
  `bootout` + `bootstrap`. That is a deliberate change, not something a skill does silently.
- **The token is a secret, not a setting.** If it ever goes server-side it goes in `setup.sql`
  like every other endpoint and region, never in a client `SET`.

Until someone makes that call, the extension is a **local `:memory:` client** capability. The
rule "no `INSTALL` on dev" is about dev; `INSTALL superhuman_docs FROM community` in an
ephemeral client is fine.

## 4. Recipe A — connector read, landed on dev (no token needed)

The connector returns JSON to the agent, so the raw response is the artifact: write it
verbatim, then let a reader type it. Never retype the content into SQL by hand.

1. `url_convert` `action: "decode"` on the browser URL → `superhuman://docs/<docId>/pages/<pageId>`.
2. `content_read` with `contentTypesToInclude: ["markdown","tables","controls","formulas"]`
   and a `markdownBlockLimit` above the page's block count. Keep `page_describe` output too —
   it carries `createdBy`/`updatedBy`/timestamps the content call omits.
3. `table_rows_read` per table the content call reports.
4. Write each response verbatim to a `.json` file, then `read_json` it from inside
   a `quack_query` body. `references/land.sql` is the shape.

Canvas-typed cells come back as `{type, content, canvasUri}`; an empty cell has **no**
`content` key at all, so the reader types it `NULL` rather than `''`. Rich-text cells come
back as `slate` JSON (`root.children[].children[].text` with `bold`/`monospace` flags), not
as strings — keep the whole struct in the raw layer and decide later.

## 5. Recipe B — extension attach (needs an API token)

```sql
LOAD superhuman_docs;
-- read_csv(path, header := false, columns := {...}) : one-line token file read by a reader;
--   no trim() -- trim strips spaces only and a trailing newline would survive.
SET VARIABLE sh_token = (SELECT t FROM read_csv(getenv('HOME') || '/.duck/superhuman.token',
                                                header := false, columns := {'t': 'VARCHAR'}));
-- CREATE SECRET name (TYPE superhuman_docs, TOKEN ...) : general secret, matches any doc.
--   Alternatives the extension names itself: attach-level TOKEN, attach-level TOKEN_ENV
--   '<var>', or a doc-scoped secret against a canonical URL.
CREATE SECRET superhuman_docs_token (TYPE superhuman_docs, TOKEN getvariable('sh_token'));
RESET VARIABLE sh_token;
-- ATTACH '<doc-id or Coda/Superhuman browser URL>' AS <alias> (TYPE superhuman_docs)
--   Browser URLs are accepted; the extension parses them before it checks auth.
ATTACH '<url>' AS doc (TYPE superhuman_docs);
```

Without credentials the attach fails with exactly:

```
Invalid Input Error: failed to resolve Superhuman Docs attach config: browser URL attachment
requires TOKEN, TOKEN_ENV, a general superhuman_docs secret, or a canonical URL with a
matching doc-scoped secret
```

That message means auth, not a bad URL. Do not retry with a different URL spelling.

## 6. The block-id wall (known, unsolved)

`content_read` returns one markdown string wrapping each block as `<block id="cl-…">…</block>`.
Splitting it into one row per block, keyed by the doc's own ids, has no clean route:

| Attempt | Result |
|---|---|
| `content::HTML` then `html_to_duck_blocks(HTML)` | `0` — reports known element types only |
| `html_extract_text(HTML, 'block')` | `0` — unknown elements are not selectable |
| `xml_extract_attributes(content::HTML, '//block')` | `0` — the HTML parser drops them from the tree |
| `html_extract_text(content::HTML)` | text survives (4758 of 6902 chars) but the ids are gone |
| `xml_wrap_fragment(content, 'canvas')` then XPath | `xml_well_formed = false`, `element_count 0` |

The XML route fails because the prose legitimately contains bare `&` and literal angle
brackets inside code spans (e.g. `` `<developer>/<issue-id>-<description>` ``). No reader on
dev understands this fragment format, so the only routes left are `regexp_*` or an escaping
pass — both banned without a petition. **Keep `content` as one column and petition the user**
rather than reaching for `regexp_extract`.

## 7. Report

- Which door, and why that one
- Doc title / page title / `superhuman://` URI / source URL
- `createdBy`, `updatedBy`, `createdAt`, `updatedAt` — pages drift, say when it was fetched
- Tables landed on dev: name, rows, columns
- Anything structurally wrong in the source (header rows stored as data, `Column 1`-style
  placeholder names, empty cells) — say it, do not silently repair it

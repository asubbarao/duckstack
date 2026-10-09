---
name: pdf-digest
description: >
  Read a long text PDF (book, report, manual, paper, 50+ pages) into a low-token, high-signal digest
  with the `pdf` extension: a markdown card (contents first, page + word count + lead sentence + tf-idf
  key terms per heading), plus glossary, figure and borderless-table relations, all from word geometry.
  Use when asked to read, summarize, digest, map or "get the gist of" a big PDF, to find where a topic
  is covered, or to pull a section, glossary term, figure list or table out of one. Not for short PDFs,
  forms, or scans — use /duckstack:pdf for those.
argument-hint: "<file.pdf> [what you want to know]"
allowed-tools: mcp__dev__execute, mcp__dev__query, Read, Bash
---

Read `/duckstack:pdf` first for the five grains. This skill is the worked answer to "the PDF is 259 pages;
what is in it?": one `.sql` file that turns `read_pdf_words` into a spine an agent can read in ~6k tokens,
then fetch any section, term or table from by key. Built and verified on *Inference Engineering* (Kiely,
259 pp), 2026-09-29, duckdb-pdf `c804ebc`.

## 1. Build the extension from its repo

The pipeline uses the layout engine of `asubbarao/duckdb-pdf` `main` (`read_pdf_words.column_index`, default
`layout := 'auto'`, merged in #21). Build the checkout; `pdf` is linked into the resulting binary:

```bash
cd ~/reviews/asubbarao-since-2025-10-01/repos/duckdb-pdf && git pull && make release   # incremental after the first build
./build/release/duckdb -noheader -list -c "SELECT extension_version FROM duckdb_extensions() WHERE extension_name='pdf'"
```

The version printed is the checked-out SHA. Verified here on `c804ebc`.

## 2. Run it

```bash
mkdir -p /tmp/x && cd /tmp/x            # card.md is written to the cwd
# doc = the PDF; gloss = a word in the glossary section's title (default 'Glossary'; no match just gives an empty pdf_glossary)
~/reviews/.../duckdb-pdf/build/release/duckdb [cache.duckdb] -cmd "SET VARIABLE doc = '/path/x.pdf'" \
  -f ~/duckdb-skills/skills/pdf-digest/references/book-digest.sql > run.out
```

A file DB argument caches the layers (the 259-page read is ~11s), so follow-up questions are millisecond queries.
Through the `dev` MCP `execute` tool, run it as `CREATE OR REPLACE TABLE digest_run AS SELECT content FROM read_lines($cmd$… -f book-digest.sql 2>&1 |$cmd$, "trim" := true)`
and read `digest_run` with `query`. Outputs: `card.md` (read this first), then `pdf_digest`, `pdf_glossary`, `pdf_figures`, `pdf_tables`,
`pdf_paras` (section text) as tables in the cache DB. `references/example-card.md` shows what the card looks like.

## 3. What the layers are (raw first, one table per statement)

| table | grain | how |
|---|---|---|
| `pdf_words` | word | `read_pdf_words`, kept whole |
| `pdf_lines` | line | y-jump > 3pt starts a line; words with a gap < 0.5pt are **glued** (ligature repair, §6); `ws` keeps every word's geometry and face; `role` = furniture / heading / kicker / toc / caption / table / note / body |
| `pdf_secs` | heading | heading lines merged when wrapped; `depth` from the dotted number; `num` = lookup key (`2.4.1`, `Ch 2`, `App A`) |
| `pdf_owned` | content line | `ASOF JOIN` to the nearest preceding heading |
| `pdf_paras` | paragraph | > 14.5pt gap starts one; line-end hyphens dehyphenated |
| `pdf_terms`, `pdf_digest`, `pdf_card` | section | tf-idf (sections as documents), lead sentence, subtree words |
| `pdf_glossary`, `pdf_figures`, `pdf_tables` | entry | leading **bold run** = term; caption from `Figure`; header cells define columns |

**Roles are relative, not hard-coded.** Body face = the modal font size. A heading is >= 1.25x body, or bold and
>= 1.05x body with <= 12 words (papers set section titles that way). Furniture is small type in the top 50pt, or any
text (digits removed) repeated in the top/bottom 15% band on 3+ pages. TOC = dot leaders (`....` or `. . . .`).
A caption starts `Figure N:`. A table line has a >= 10pt gap between words. Heading depth is the dotted number when the
document has numbered headings, else the font-size rank. Only `Figure`, the leader test and the `gloss` word are vocabulary.

## 4. Reading recipes (against the cache DB)

```sql
-- a section's text by number, in reading order
SELECT p.page, p.ptext FROM pdf_paras p JOIN pdf_secs s ON p.sec_id = s.sec_id WHERE s.num = '2.4.1' ORDER BY p.seq;
-- where is a topic? sections ranked by term hits
SELECT s.num, s.title, s.page FROM pdf_terms t JOIN pdf_secs s ON t.sec_id = s.sec_id WHERE list_contains(t.terms, 'kv') ORDER BY s.page;
-- a glossary term / all figures on a page / a table's rows
SELECT * FROM pdf_glossary WHERE term ILIKE '%attention%';
SELECT * FROM pdf_figures WHERE page BETWEEN 60 AND 70;
SELECT * FROM pdf_tables WHERE page = 30 ORDER BY block_id, row_id;
```

## 5. Point it at another PDF

Run the typographic census first and read it before trusting any role; if body is not the modal size (slides,
two-column papers), fix the census, not the roles:

```sql
-- pdf_lines built as in the file; then:
SELECT replace(font_name, split_part(font_name, '-', 1) || '-', '') AS face, font_size, round(font_size / body_fs, 2) AS ratio,
       len(list(text)) AS n_lines, len(list(DISTINCT page)) AS n_pages, list(text ORDER BY page, y0)[1:2] AS sample
FROM pdf_lines GROUP BY face, font_size, body_fs ORDER BY n_lines DESC;
```

Tested on three documents (2026-09-29, `c804ebc`). Two are public and reproducible, from the repo's own network tests:

| document | pages | headings found | outline | notes |
|---|---|---|---|---|
| *Inference Engineering* (book, 6x9in) | 259 | 156 | 146/146 | numbered, three heading levels, glossary of 213 terms |
| DuckLake docs `blobs.duckdb.org/docs/ducklake-docs.pdf` | 104 | 224 | 83/83 | no numbered headings: depth from font rank; see `example-card-ducklake.md` |
| ICDE 2015 paper `blobs.duckdb.org/papers/stonebraker-centintemel-one-size-fits-all-icde-2015.pdf` | 10 | 21 | none | two-column; headings are body-size bold; columns interleave on pages 1, 3, 6, 9 (extension defect, see findings B6) |

Known limits: bold table-of-contents entries without dot leaders (`Summary 1`) become tiny headings under "Contents";
large figure labels become false headings; a page the extension fails to split into columns reads interleaved.

The three witnesses at the bottom of the file must pass: characters conserved between `pdf_words` and `pdf_lines`;
headings found from geometry match `pdf_outline` (146/146 here; skip if the PDF has no outline); `pdf_pages_info.label`
(the PDF's own printed page numbers) equals the running-header parse.

## 6. Traps found doing this (all verified on `c804ebc`)

- **Ligatures split words**: `Profi ling`, `fi rst`. poppler emits the `fi` glyph run and the rest as separate words
  0.2pt *overlapping*; the extension inserts a space (192 broken words in this book: 150 `fi`, 25 `fl`, 17 `ff`).
  Glue words whose gap is < 0.5pt on the same line. Real spaces are >= 2.5pt. `read_pdf_lines`/`elements` text is
  already spaced, so build text from `read_pdf_words`.
- `try_cast('1.2' AS INTEGER)` is **1**, not NULL. A header `1.2 About Your App 27` parsed as page 1. Round-trip the cast.
- `read_pdf_tables` finds a borderless table on 3 of this book's 19 table pages, fires on 5 TOC pages, and on 2 pages
  mixes body prose into the rows. Use §3's word-geometry tables instead (21 blocks, all checked).
- `pdf_outline` has no page column; `pdf_destinations` returns 0 rows here although the outline is `/GoTo` + `/D`.
  Join outline titles to geometry headings (normalise spaces) to get pages.
- `read_pdf_elements` types two 7.5pt running headers as `heading` (`4.1 CUDA 97`) and has no font face column.
- `pdf_chunks(file, chunk_size)` takes only `chunk_size` positionally; `overlap`, `first_page`, `last_page` are named.
- Window calls cannot nest (`sum(CASE WHEN lag(...) ...)`): compute the `lag` in one CTE, the `sum` in the next.
- `layout` is only a parameter of `read_pdf`, `read_pdf_lines`, `pdf_to_text`; words/layout/tables ignore it.

Details, evidence and suggested fixes: `references/pdf-extension-findings.md`.

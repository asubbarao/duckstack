---
name: pdf-digest
description: >
  Turn a folder of PDFs (books, reports, manuals, papers, forms, decks) into one contents-first markdown card per
  file with the published `pdf` extension: each file's own outline, or the headings `pdf_chunks` finds when there is
  none, with the pages every section spans and its chunks kept as rows. Use when asked to read, map, digest or "get the
  gist of" PDFs, to find where a topic is covered, or to pull a section's text. Single-page detail is /duckstack:pdf.
argument-hint: "<glob of PDFs> [what you want to know]"
allowed-tools: mcp__dev__query, mcp__dev__execute, Read
---

Read `/duckstack:pdf` first for the readers. This skill uses only what each PDF declares and what the extension
segments: `pdf_outline` (the file's contents: `file, ord, depth, title`) and `pdf_chunks` (`file, chunk_idx, text,
page_start, page_end, n_chars, heading`). No font-size thresholds or vocabulary, so it works the same on any PDF.

## Run it

`references/book-digest.sql`: edit the glob in its two source reads, then on dev (shellfs, self-dispatched):

```sql
SELECT http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql',
  $s$SELECT line_number, content FROM read_lines('cd <out dir> && duckdb :memory: -f /Users/aloksubbarao/duckdb-skills/skills/pdf-digest/references/book-digest.sql 2>&1 |')$s$))
```

It writes `cards.md` to that directory and leaves `pdf_sections` (one row per contents entry, every chunk under it
with its pages and text) and `pdf_card` (one card per file). Verified on dev 2026-10-09 over `~/Downloads/*.pdf`:
a 259-page book (146 outline entries), a resume, a CI report, a form, a lab and two decks; 188 card lines.

## Reading it

```sql
-- a section's text, in order
SELECT c.page_start, c.text FROM pdf_sections s, UNNEST(s.chunks) AS t(c) WHERE s.title = '2.2.3 Attention' ORDER BY c.chunk_idx;
-- where a topic is covered: full-text search over the chunks (fts), ranked by BM25
```

## Known gaps

- An outline entry whose title differs from the chunk heading beyond case and spaces gets no pages
  ("Chapter 0: Inference", "1.3.2 Fine-Tuning for Domain- Specific Quality" in the test book).
- Some exporters write a placeholder outline ("Slide Number 2"); the card shows what the file declares.
- `pdf_outline` has no page column; pages come only from the matched chunks.

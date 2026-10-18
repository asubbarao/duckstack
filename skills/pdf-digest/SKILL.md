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

`references/book-digest.sql` is one `COPY` statement: edit the glob in its two source reads, then run it on dev
through shellfs in a `:memory:` client (one literal reader call, no dispatch needed):

```sql
SELECT line_number, content
FROM read_lines('cd <out dir> && duckdb :memory: -f /Users/aloksubbarao/duckdb-skills/skills/pdf-digest/references/book-digest.sql 2>&1 |');
```

It writes `cards.md` (one card per file) to that directory and leaves no tables. Verified on dev 2026-10-17 over five
PDFs in `~/Downloads` (two outlines, three from chunk headings); 2026-10-09 over the whole folder, including a
259-page book with 146 outline entries.

## Reading it

```sql
-- a section's text, in order: the chunks pdf_chunks filed under that heading
SELECT page_start, text FROM pdf_chunks('<file>.pdf') WHERE heading = '2.2.3 Attention' ORDER BY chunk_idx;
-- where a topic is covered: full-text search over the chunks (fts), ranked by BM25
```

## Known gaps

- An outline entry whose title differs from the chunk heading beyond case and spaces gets no pages
  ("Chapter 0: Inference", "1.3.2 Fine-Tuning for Domain- Specific Quality" in the test book).
- Some exporters write a placeholder outline ("Slide Number 2"); the card shows what the file declares.
- `pdf_outline` has no page column; pages come only from the matched chunks.

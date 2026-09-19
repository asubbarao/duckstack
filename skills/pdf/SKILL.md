---
name: pdf
description: >
  PDFs as tables, with the `pdf` community extension — never poppler CLI, pypdf, pdfplumber
  or any Python library. Use when the user gives a .pdf path or URL, says read/extract/parse
  this PDF, asks what a document says, wants its tables, forms, metadata, signatures or page
  images, or wants a PDF merged, split, rotated, redacted or written. Reads at five grains
  (page, line, word+bbox, layout element, retrieval chunk) and renders pages to PNG without
  pdftoppm.
argument-hint: "<file.pdf | glob | url> [question about the document]"
allowed-tools: Bash
---

You are reading a PDF into tables. Read `/duckstack:duck` first. The deliverable is one
`.sql` artifact whose `SELECT *` is a tabular grid of the document.

Input: `$0` — path, glob or URL. Question: `${1:-describe the document}`.

## The rule that matters most

**Pass no `layout` at all.** The default is `'auto'`, a geometric column
detector: it finds the whitespace corridors a page actually has, assigns every
word to a column band, and emits the bands left to right. On a calendar, an
invoice, a two-column paper or a form, that is the reading order a person sees.

The other values exist because they answer different questions, and each is
worse than the default for reading a document:

- `'physical'` pads with spaces to imitate the printed page. It preserves
  alignment but fuses a prose column into the grid row beside it, because it has
  no idea what a column is.
- `'reading'` emits each text run on its own line and discards horizontal
  position, so columns interleave. Output looks clean and is wrong.
- `'raw'` is content-stream order — useful only to see how the file was authored.
- An unrecognised value throws:
  `layout must be one of ['auto', 'physical', 'reading', 'raw'], not 'banana'`.

Measured on the DuckDB Friendly SQL Calendar, page 2, with the build installed
here (`bef4b27`):

    default            MON TUE WED THU FRI SAT SUN
                       1 2 3 4                       <- 1 Jan 2026 is a Thursday
    layout 'physical'  PREFIX ALIASES     MON   TUE   WED   THU   FRI   SAT   SUN

**Version caveat.** `'auto'` and the fail-loud validation land in 0.9.0. The
published community build (0.8.0, `6535c81`) still defaults to `'reading'` and
still falls back silently on a bad value — against that build, and only that
build, `layout := 'physical'` is the least-bad workaround.

## The five grains — pick by what the question needs

```sql
LOAD pdf;
-- read_pdf(files, layout := 'auto', parse_tables := false, first_page := NULL,
--          last_page := NULL, password := NULL, ignore_errors := false, ocr := false,
--          auto_ocr := false, ocr_language/ocr_dpi/ocr_psm/ocr_oem/ocr_preprocess/
--          ocr_retry/tessdata_dir/ocr_backend/ocr_plugin/ocr_endpoint := defaults)
```

| grain | function | columns |
|---|---|---|
| page | `read_pdf` | `filename, page, page_count, text, width, height, has_text_layer, used_ocr` |
| line | `read_pdf_lines` | `filename, page, line, text` |
| **word** | `read_pdf_words` / `read_pdf_layout` | `filename, page, word, x0, y0, x1, y1, font_name, font_size, source, confidence` |
| element | `read_pdf_elements` | `file, page_number, element_idx, element_type, text, font_size, bbox_x0..bbox_y1` |
| table | `read_pdf_tables` | `filename, page, table_index, row_index, cells` |
| chunk | `pdf_chunks(file, chunk_size, overlap, first_page, last_page, password)` | `file, chunk_idx, text, page_start, page_end, n_chars, heading` |

**`read_pdf_words` is the substrate.** It is the only grain that keeps geometry,
so it is the one to reach for whenever the layout carries meaning. Coordinates
are points, origin top-left, `y0` growing downward. Lines are a `GROUP BY`, not
a parameter:

```sql
SELECT page, y0, list(word ORDER BY x0) AS words, array_to_string(words, ' ') AS line
FROM read_pdf_words(getvariable('doc')) GROUP BY page, y0;
```

Columns are the same trick on `x0`, joined to whatever row is the header. `font_name`
often carries the semantics the text lost — bold for weekends, a heading face for
headings. Keep it.

## Inspect, render, transform

| want | call | columns / result |
|---|---|---|
| file census | `pdf_info(file, password)` | `file, title, author, …, page_count, is_encrypted, is_linearized, pdf_version, width, height, file_size, pdfa_part, pdfa_conformance` |
| per-page geometry | `pdf_pages_info` | `file, page, width, height, media_*, crop_*, rotation, orientation, label, duration` |
| metadata only | `read_pdf_meta` | `filename, title, …, pages, pdf_version, encrypted` |
| bookmarks | `pdf_outline` | `file, ord, depth, title` |
| fonts / forms / annotations / attachments / signatures / revisions | `pdf_fonts`, `pdf_form_fields`, `pdf_annotations`, `pdf_attachments`, `pdf_signatures`, `pdf_revisions` | — |
| embedded images | `pdf_images` | `file, page, image_index, name, width, height, bits_per_component, colorspace, format, data` |
| page pictures | `pdf_page_images(file, dpi, first_page, last_page, password)` → PNG BLOB per page; `pdf_write_page_images(file, out_dir, dpi, …)` → `out_dir/<stem>/p{N}.png` | no `pdftoppm` needed |
| whole document as one string | `pdf_to_text(src, layout)`, `pdf_to_markdown`, `pdf_to_html`, `pdf_to_xml`, `pdf_to_svg`, `pdf_to_png` | path, glob **or** BLOB |
| surgery | `pdf_merge`, `pdf_split`, `pdf_split_blank`, `pdf_rotate`, `pdf_pages`, `pdf_compress`, `pdf_encrypt`, `pdf_decrypt`, `pdf_watermark`, `pdf_bates`, `pdf_redact` / `pdf_redact_lateral`, `pdf_sign` | writes files |
| write one | `write_pdf`, `to_pdf`, `COPY … TO 'x.pdf' (FORMAT pdf)` | — |

`pdf_to_html` and `pdf_to_xml` carry per-word `left/top/font-size` and
`xMin/yMin/xMax/yMax`. They are a whole-document VARCHAR, so reading them means
casting and using a reader — never string surgery:

```sql
LOAD webbed;
FROM read_xml(f, record_element := 'page', all_varchar := true);  -- number, width, height, word[]
```
Prefer `read_pdf_words`; the XML route is for when you need the document and its
geometry in one value.

## Scanned pages

`has_text_layer` is the check, not a guess. `auto_ocr := true` OCRs only the
pages that have none; `ocr := true` forces it everywhere. English tessdata is
bundled. `read_pdf_words.source` says `text` or `ocr` per word and `confidence`
scores it — filter on confidence, never on a hunch.

## Gotchas

- Positional arguments show as `col0, col1, col2` in `duckdb_functions()` and every
  description is NULL. The named parameters are real; the positional ones are not
  discoverable from inside DuckDB. Check the repo README
  (`asubbarao/duckdb-pdf`) before guessing at `pdf_bates`, `pdf_redact`, `pdf_sign`.
- The source-file column is `filename` on the `read_pdf*` family but `file` on
  `pdf_info`, `pdf_chunks`, `pdf_pages_info`, `pdf_fonts`, `pdf_outline`,
  `pdf_images`; `read_pdf_elements` says `page_number` where everything else says
  `page`, and `bbox_x0` where `read_pdf_words` says `x0`. Alias on the way in.
- `read_pdf_meta.encrypted` and `pdf_info.is_encrypted` are the same fact under two
  names; `read_pdf_meta.pages` and `pdf_info.page_count` likewise.
- Table functions bind literals. Per-file fan-out is `SET VARIABLE` + a glob, or
  `/duckstack:self-dispatch`; `pdf_redact_lateral` exists because `pdf_redact`
  cannot take a column.
- Claude Code's own PDF reader shells out to `pdftoppm`. If it errors with
  "poppler-utils not installed", do not install poppler — render with
  `pdf_write_page_images` and read the PNGs.

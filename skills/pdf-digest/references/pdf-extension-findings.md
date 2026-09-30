# duckdb-pdf findings from reading a real 259-page book

Source: *Inference Engineering* (Kiely, InDesign 16.4, 432x648pt, 259 pp), read 2026-09-29 on duckdb-pdf `c804ebc`
(branch `layout-auto-default`, PR #21). Every item was measured, not inferred; queries are in `book-digest.sql` or quoted
here. Ranked by how much each costs a reader. Two review notes on the layout engine are at the end.

## Status (2026-09-29): each has a fix on its own branch off `main`

| # | Fix branch | Commit | Measured result |
|---|---|---|---|
| B1 | `fix/pdf-glue-ligature-runs` | `a9e3ed3` | 192 split words -> 0 on the book; word count falls by exactly the touching pairs on all 8 test PDFs; also joins superscript ordinals (`26`+`th`) in the Hetzner deck |
| B2 | `fix/pdf-tables-region-segmentation` | `5b119c2` | book 3 -> 19 of 19 table pages; DuckLake docs 21 -> 46; calendar unchanged at 12 (a whole-page floor keeps tables that were found before) |
| B3 | `fix/pdf-elements-caps-heading-size-gate` | `fd3f64f` | false headings 2 -> 0; other heading counts unchanged |
| B4 | `feat/pdf-outline-page` | `f19de80` | `pdf_outline.page`: 146/146 (book) and 83/83 (DuckLake) match an independent geometry-derived page |
| B6 | `fix/pdf-layout-gutter-crossers` | see branch | ICDE paper 6 -> 10 of 10 pages split; book, DuckLake, calendar and both decks exactly at their old baseline |

How they were verified matters more than the numbers: every fix was run on ALL public test PDFs and the book, old build vs new, and
accepted only if nothing else moved. Two of the first drafts passed their own acceptance query while regressing other documents
(details in the B2 and B6 notes below). Not yet done: I1-I4 (labels, `line_id`, element roles), the codepoint-width note.

## Bugs

**B1. Ligature runs split words (read_pdf_words, read_pdf_lines, read_pdf_elements, read_pdf).**
`4.5.3 Profi ling Performance`; `fi rst`, `defi ne`, `signifi cant`. Evidence: `read_pdf_words` p116 returns `Profi` (x1 104.5) and
`ling` (x0 104.3), a gap of **-0.2pt**, yet the line text reads `Profi ling`. 192 broken words in the book (150 `fi`, 25 `fl`,
17 `ff`). It also defeats string comparison against `pdf_outline` (`Prefi x` vs `Prefix`) and every full-text search for a
word containing a ligature.
Likely cause (read, not yet proven by a run): `LayoutWordsFromBoxes` (src/pdf_extension.cpp ~603) takes poppler `text_box`es as
they come, and `poppler::text_box::has_space_after()` is never called anywhere in `src/`. Suggested fix: carry
`has_space_after` (or the geometric test `next.x0 - cur.x1 < 0.5pt` on one line) into `LayoutWord` and merge those boxes
before line/word emission. Workaround that works today: glue words with gap < 0.5pt in SQL (in `book-digest.sql`).

**B2. read_pdf_tables: poor recall and precision on borderless tables.**
On this book it fires on 8 pages: 5 are the dot-leader TOC (pp5-9); p90 is a clean real table; on pp123 and 141 it finds the
real tables but emits body-prose paragraphs and the running header (`5.1.1 Number Formats 121`) as rows of the same table.
It misses 16 of the 19 table pages, including p30, a plain 3-column table with wrapped cells. A 25-line SQL over
`read_pdf_words` (header line = first table line, columns = header cell x0, a word in column 1 starts a row, other lines
continue it) finds tables on all 19 pages: 21 blocks, 109 rows, every block checked by eye against its first rows (GPU specs,
engine comparisons, number formats, memory hierarchy, ...).
Suggested: a stream mode keyed on the same header/column-edge idea, and reject blocks whose "columns" are ragged prose.

**B3. read_pdf_elements types running headers as headings.** `4.1 CUDA 97` (p99) and `5.2.3 EAGLE 133` (p135) at 7.5pt come
back `element_type = 'heading'`. Cause (confirmed by the fix): rule 4b classified any short ALL-CAPS block as a heading at any font
size, and `4.1 CUDA 97` contains the all-caps word `CUDA`. Also
`CHAPTER 0` (10pt kicker) is a `heading`. It exposes no `font_name`, so bold/italic/mono cannot be recovered at that grain, and table
rows come back as one `paragraph` per line with cells joined by single spaces.

**B6. Column detection is all-or-nothing per page.** On the repo's own two-column test paper (ICDE 2015, 10 pp), `read_pdf_words`
splits `column_index` 0/1 on pages 2, 4, 5, 7, 8, 10 and leaves pages 1, 3, 6, 9 as one column (x 74..562), so their reading
order interleaves the columns in every grain. Page 1: ONE word straddles the gutter (`Whose`, a 14pt title word) of ~574; page 6: ONE
(`“Count100”`, a table cell) of ~658. Pages 3 and 9: no word straddles, and they still do not split (hypothesis, unproven: gaps of the
gutter's width inside figures/tables put the same-width class below `min_band`, which vetoes the real gutter too).
Code: `LayoutGutters` (:390, a corridor survives only if NO word crosses it) and `LayoutColumnBands` (:413-516, same-width classes accepted
or rejected whole). Fix direction: tolerate a tiny fraction of crossing words, and let the corridor that separates most lines win over
figure/table gaps. Guard rails: the calendar's 7-wide grid must stay whole, `test/data/table.pdf` must not split.

## Missing capability (each is a definite improvement)

**I1. pdf_outline has no page.** Columns are `file, ord, depth, title`. The file has the targets (`pdf_json` contains
`/GoTo` and `/D`), but `pdf_destinations` returns 0 rows for this file and there is no way to join a bookmark to a page.
Add `page` (resolve `/Dest` and `/A` GoTo). I recovered pages by matching outline titles to geometry headings: 146/146.

**I2. Printed page numbers are already in the file but not in the readers.** `pdf_pages_info.label` returns `A`, `1`, `3`, `28`,
`257` (the PDF's `/PageLabels`), agreeing with the running header on all 224 pages that have one. `read_pdf*` only report the
physical page; a `label` column on `read_pdf`/`read_pdf_lines`/`read_pdf_words` would remove the header-parsing hack.

**I3. read_pdf_words has no `line_id`.** The layout engine computes lines (that is what `read_pdf_lines` is), but the word grain
returns only `column_index`, so every consumer re-derives lines from `y0` (in this file: y jump > 3pt).

**I4. Roles.** What `book-digest.sql` derives from size/position/geometry (furniture, kicker, caption, table, note) is what a
document-structure reader needs. `read_pdf_elements` could expose `depth`, `font_name`, and `furniture`/`caption`/`table_row`
types instead of `paragraph`.

## Doc/skill corrections

- `/duckstack:pdf` lists `pdf_chunks(file, chunk_size, overlap, ...)` as positional. Only `chunk_size` is positional;
  `pdf_chunks(f, 1500, 0)` fails with "No function matches ... (VARCHAR, INTEGER, INTEGER)". Use `overlap := 0`.
- `pdf_info` reports width 432.0 while `pdf_pages_info` reports 432.00019999999995 for the same pages; compare with a tolerance.

## Review notes on the layout engine (src/pdf_extension.cpp:336-599, read first-hand)

- `LayoutPageText` (line 592) joins every word with a single space, so B1's split survives into `read_pdf`/`read_pdf_lines` text
  even if the word grain is fixed; the merge belongs before both.
- `LayoutMedianCharWidth` divides by `w.text.size()` (bytes). For multibyte text (CJK, accented, `•`) the "character width" is
  undersized, which shrinks the 3-char gutter and 20-char band thresholds. Count codepoints. Not exercised on a non-Latin
  document, so unmeasured.
- Design is otherwise sound: gutters by running-max sweep, equal-width gaps accepted as a class, display type excluded from the
  gutter vote, band cap of 8, thresholds explained by measured cases in the comments.

## Checked and fine

`read_pdf_words` over 259 pages: ~10s, 2 threads. `pdf_write_page_images(file, out_dir, dpi := 80, first_page := N, last_page := N)`
writes `out_dir/<stem>/p{N}.png`, and `Read` shows it: the right way to eyeball a page. Font faces and sizes are exact
(`HelveticaLTStd-Bold` 13.5 = section, `-Roman` 12.75 = subsection). Words conserve: 279,418 characters in, 279,418 in lines.

## Slide decks: a 5-page PowerPoint export (entity org-chart slides), 2026-09-29

Read on #28's build, then checked against every page rendered at 110 dpi.

| grain | result against the pixels |
|---|---|
| `read_pdf_words` / lines | Every word captured, prose slides word for word. Card slides split into the right 3 column bands, cards in order top to bottom. Superscript `3rd` glued correctly. |
| word geometry → cards (`references` query: 14pt line starts a card, ASOF-attach 10pt lines, italic = property) | Page 3: 16/16 cards exact (name, property, every bullet). Page 5: 16/16 after two query fixes: sizes must be read per word (a 16pt badge shares the 14pt heading's baseline and merges into one line) and a badge attaches to the nearest heading in either direction (it overlaps its card's top edge). Co-invest boxes pair with their SPE by y alone: 6/6. |
| `read_pdf_tables` | **Defect.** Both card slides come back as tables. Page 3 is a plausible 3×26 grid but cards shear across rows and a red bullet splits from its text into the next row; page 5 is garbage (3 bands collapsed into 2 columns, cards concatenated). A card layout is not a table, and a detector should return nothing rather than this. |
| `read_pdf_elements` | Body-size ALL-CAPS entity names in the co-invest boxes typed `heading`; a badge merged into the heading below it (`Sold: 10/24 VOP REF Virginia, LLC`). |
| reading order | **Defect.** Page 3's centred slide title sits over the middle column and is emitted as that column's first line, after the whole left column. The page-5 badge `Sabraw Property Purchased: 5/26` crosses the gutter and is sliced into two bands (same class as the full-width-title regression being fixed on #28). |
| color | **Gap.** The red status lines ("Managed and insured by others", "Expected sale") are the slide's flags, and no output carries color: words have none, `pdf_to_html` spans have none, `pdf_to_svg` embeds the page as one PNG. Only the pixels have it. poppler-cpp's `text_box` exposes no color; it would need the core `TextWord` color. |
| `pdf_images` | 0 rows, correct: the logo is vector artwork. |

-- Book digest: a long text PDF -> a low-token, high-signal markdown card, plus glossary / figure / table relations.
-- duckdb-pdf head (>= c804ebc).   Run:  duckdb [file.duckdb] -f book_digest.sql      Change the doc on the next line.
--
-- Layers, raw first, one table per statement (tables so a file DB caches the 12s PDF read; in :memory: they are just steps):
--   pdf_words -> pdf_lines (glued words, geometry, typographic role) -> pdf_secs (heading tree) -> pdf_owned (content by heading)
--   -> pdf_paras -> pdf_terms -> pdf_digest -> { pdf_card, pdf_glossary, pdf_figures, pdf_tables }
-- Nothing here is per-book except the two SET VARIABLEs: the file, and the word that names a glossary section.
.mode csv
-- Override either from the command line: duckdb -cmd "SET VARIABLE doc = 'x.pdf'" -f book-digest.sql
SET VARIABLE doc = coalesce(getvariable('doc'), '/Users/aloksubbarao/Downloads/Inference Engineering.pdf');
SET VARIABLE gloss = coalesce(getvariable('gloss'), 'Glossary');

-- L0 raw: every word with geometry and face. read_pdf_words(files, first_page := NULL, last_page := NULL, password := NULL,
--   ignore_errors := false, ocr := false, auto_ocr := false, ocr_language/ocr_dpi/ocr_psm/ocr_oem/ocr_preprocess/ocr_retry/
--   tessdata_dir/ocr_backend/ocr_plugin/ocr_endpoint := defaults)
CREATE OR REPLACE TABLE pdf_words AS
SELECT page, column_index AS col, word, x0, y0, x1, y1, font_name, font_size
FROM read_pdf_words(getvariable('doc'));

-- L1 lines. A new line starts when y0 jumps > 3pt within (page, column). Words are then glued where poppler split a ligature
-- ("Profi" + "ling" overlap by 0.2pt; a real space is >= 2.5pt, so gap < 0.5 means one word). ws keeps every glued word with
-- geometry, face and the gap before it, so line-level summaries lose nothing.
CREATE OR REPLACE TABLE pdf_lines AS
WITH w1 AS (
  SELECT *, y0 - lag(y0) OVER pc AS dy FROM pdf_words WINDOW pc AS (PARTITION BY page, col ORDER BY y0, x0)
),
w2 AS (
  SELECT *, sum(CASE WHEN dy IS NULL THEN 1 WHEN dy > 3 THEN 1 ELSE 0 END) OVER (PARTITION BY page, col ORDER BY y0, x0) AS line_id FROM w1
),
w3 AS (SELECT *, x0 - lag(x1) OVER pl AS gap FROM w2 WINDOW pl AS (PARTITION BY page, col, line_id ORDER BY x0)),
w4 AS (
  SELECT *, sum(CASE WHEN gap IS NULL THEN 1 WHEN gap >= 0.5 THEN 1 ELSE 0 END) OVER (PARTITION BY page, col, line_id ORDER BY x0) AS word_id FROM w3
),
gw0 AS (
  SELECT page, col, line_id, word_id, string_agg(word, '' ORDER BY x0) AS word, min(x0) AS x0, max(x1) AS x1, min(y0) AS y0, max(y1) AS y1,
         mode(font_name) AS font_name, max(font_size) AS font_size
  FROM w4 GROUP BY page, col, line_id, word_id
),
gw AS (SELECT *, x0 - lag(x1) OVER (PARTITION BY page, col, line_id ORDER BY x0) AS gap_prev FROM gw0),
l AS (
  SELECT page, col, line_id, string_agg(word, ' ' ORDER BY x0) AS text, len(list(word)) AS n_words,
         min(x0) AS x0, max(x1) AS x1, min(y0) AS y0, max(y1) AS y1, mode(font_name) AS font_name, mode(font_size) AS font_size,
         list({'w': word, 'x0': x0, 'x1': x1, 'f': font_name, 'gap': gap_prev} ORDER BY x0) AS ws
  FROM gw GROUP BY page, col, line_id
),
l2 AS (
  SELECT *, mode(font_size) OVER () AS body_fs, page * 10000 + y0 AS seq, max(y1) OVER () AS page_h,
         list_max(list_transform(ws, x -> coalesce(x.gap, 0))) AS max_gap,
         translate(text, '0123456789', '') AS tmpl,
         len(list_filter(['bold', 'blk', 'black', 'heavy'], x -> contains(lower(font_name), x))) > 0 AS is_bold
  FROM l
),
-- furniture by repetition: the same text (digits removed, so a page number does not matter) in the top or bottom 15% band on 3+ pages
rep AS (
  SELECT tmpl, band, len(list(DISTINCT page)) AS n_pages
  FROM (SELECT page, tmpl, CASE WHEN y0 < 0.15 * page_h THEN 'top' WHEN y0 > 0.85 * page_h THEN 'bottom' END AS band FROM l2)
  WHERE band IS NOT NULL AND length(tmpl) > 0 GROUP BY tmpl, band
),
l2r AS (
  SELECT l2.*, coalesce(rep.n_pages, 0) >= 3 AS repeats
  FROM l2 LEFT JOIN rep ON l2.tmpl = rep.tmpl AND rep.band = CASE WHEN l2.y0 < 0.15 * l2.page_h THEN 'top' WHEN l2.y0 > 0.85 * l2.page_h THEN 'bottom' END
),
-- role = size relative to the body face + position + geometry. A table line has cells (a >= 10pt gap between words); small prose is a note.
-- A heading is larger than 1.25x body, or bold and larger than 1.05x body and short (papers set section titles that way).
l3 AS (
  SELECT *,
    CASE
      WHEN font_size IS NULL THEN 'none'
      WHEN font_size < body_fs AND y0 < 50 THEN 'furniture'
      WHEN repeats THEN 'furniture'
      WHEN contains(text, '....') THEN 'toc'
      WHEN contains(text, '. . . .') THEN 'toc'
      WHEN starts_with(text, 'Figure ') AND ends_with(split_part(text, ' ', 2), ':') THEN 'caption'
      WHEN font_size >= 1.25 * body_fs THEN 'heading'
      WHEN font_size > body_fs AND upper(text) = text THEN 'kicker'
      WHEN is_bold AND font_size >= 1.05 * body_fs AND n_words <= 12 THEN 'heading'
      WHEN font_size < body_fs AND starts_with(text, 'Figure') THEN 'caption'
      WHEN font_size < body_fs AND max_gap >= 10 THEN 'table'
      WHEN font_size < body_fs THEN 'note'
      ELSE 'body'
    END AS role0
  FROM l2r
),
-- a caption wraps: a small line directly under a caption, same size, is its continuation (applied twice for 3-line captions)
l4 AS (
  SELECT *, lag(role0) OVER pg AS prole, lag(font_size) OVER pg AS pfs, y0 - lag(y0) OVER pg AS pdy
  FROM l3 WINDOW pg AS (PARTITION BY page ORDER BY seq)
),
l5 AS (
  SELECT *, CASE WHEN role0 IN ('note', 'table') AND prole = 'caption' AND font_size = pfs AND pdy < 14 THEN 'caption' ELSE role0 END AS role1
  FROM l4
),
l6 AS (SELECT *, lag(role1) OVER pg AS prole1 FROM l5 WINDOW pg AS (PARTITION BY page ORDER BY seq))
SELECT * EXCLUDE (role0, prole, pfs, pdy, role1, prole1),
       CASE WHEN role1 IN ('note', 'table') AND prole1 = 'caption' AND font_size = pfs AND pdy < 14 THEN 'caption' ELSE role1 END AS role
FROM l6;

-- L2 heading tree. depth: chapter 1; unnumbered (chapter intro, Preface) 2; numbered = its dotted parts (1.1 -> 2, 1.2.1 -> 3).
-- A title that wraps (36pt "Recommended" / "Reading") is several heading lines of one size on one page: they are one heading.
-- num is the lookup key: '2.4.1' for numbered headings, 'Ch N' / 'App X' for chapters and appendices (from the kicker line).
CREATE OR REPLACE TABLE pdf_secs AS
WITH h0 AS (
  SELECT page, seq, text, role, font_size, body_fs,
         lag(role) OVER ol AS prev_role, lag(text) OVER ol AS prev_text, lag(page) OVER ol AS prev_page,
         lag(font_size) OVER ol AS prev_fs, lag(seq) OVER ol AS prev_seq
  FROM pdf_lines WHERE role IN ('heading', 'kicker') WINDOW ol AS (ORDER BY seq)
),
h1 AS (
  SELECT *, CASE WHEN role = 'heading' AND prev_role = 'heading' AND prev_page = page AND prev_fs = font_size
                      AND seq - prev_seq < 1.6 * font_size THEN 0 ELSE 1 END AS starts
  FROM h0
),
h2 AS (SELECT *, sum(starts) OVER (ORDER BY seq) AS head_id FROM h1),
h3 AS (
  SELECT head_id, min(page) AS page, min(seq) AS seq, string_agg(text, ' ' ORDER BY seq) AS text, min(role) AS role,
         min(font_size) AS font_size, min(body_fs) AS body_fs, list(prev_text ORDER BY seq)[1] AS prev_text, list(prev_role ORDER BY seq)[1] AS prev_role
  FROM h2 GROUP BY head_id
),
-- tok drops a trailing dot so "1. Introduction" is numbered; a document with no numbered headings takes depth from font-size rank.
h4 AS (
  SELECT *, rtrim(split_part(text, ' ', 1), '.') AS tok,
         coalesce(length(tok) > 0 AND list_bool_and(list_transform(string_split(tok, '.'), x -> try_cast(x AS INTEGER) IS NOT NULL)), false) AS numbered
  FROM h3
),
h5 AS (
  SELECT *, bool_or(numbered) OVER () AS any_numbered, dense_rank() OVER (PARTITION BY numbered ORDER BY font_size DESC) AS size_rank
  FROM h4
)
SELECT row_number() OVER (ORDER BY seq) AS sec_id, count(seq) OVER () AS n_sec, page, seq,
  CASE WHEN font_size >= 3 * body_fs THEN 1 WHEN numbered THEN len(string_split(tok, '.')) WHEN any_numbered THEN 2 ELSE size_rank END AS depth,
  CASE WHEN font_size >= 3 * body_fs AND prev_role = 'kicker'
       THEN array_to_string(list_transform(string_split(prev_text, ' '), x -> upper(left(x, 1)) || lower(substr(x, 2))), ' ') || ': ' || text
       ELSE text END AS title,
  CASE WHEN font_size >= 3 * body_fs AND prev_role = 'kicker'
            THEN CASE WHEN starts_with(prev_text, 'CHAPTER') THEN 'Ch ' ELSE 'App ' END || split_part(prev_text, ' ', 2)
       WHEN numbered THEN tok END AS num
FROM h5 WHERE role = 'heading';

-- L3 ownership: every content line belongs to the nearest preceding heading.
CREATE OR REPLACE TABLE pdf_owned AS
SELECT r.*, s.sec_id
FROM pdf_lines r ASOF LEFT JOIN pdf_secs s ON r.seq >= s.seq
WHERE r.role IN ('body', 'table', 'caption', 'note');

-- Printed page number from the running header (7.5pt, top margin); the mode of (pdf page - printed) fills pages that carry none.
-- try_cast('1.2' AS INTEGER) is 1, not NULL: a header "1.2 About Your App 27" would read as page 1. Round-trip to demand a bare integer.
CREATE OR REPLACE TABLE pdf_pages AS
WITH f AS (
  SELECT page, split_part(text, ' ', 1) AS a, split_part(text, ' ', -1) AS z,
         CASE WHEN a = CAST(try_cast(a AS INTEGER) AS VARCHAR) THEN try_cast(a AS INTEGER)
              WHEN z = CAST(try_cast(z AS INTEGER) AS VARCHAR) THEN try_cast(z AS INTEGER) END AS printed
  FROM pdf_lines WHERE role = 'furniture'
),
-- pdf_pages_info.label is the PDF's own /PageLabels (printed numbering); the header parse is kept only as a cross-check and fallback.
-- pdf_pages_info(file, password := NULL) -> file, page, width, height, media_*, crop_*, rotation, orientation, label, duration
j AS (
  SELECT i.page, i.label, f.printed AS printed_hdr,
         coalesce(i.label, CAST(f.printed AS VARCHAR), CAST(i.page - mode(i.page - f.printed) OVER () AS VARCHAR)) AS printed_page
  FROM pdf_pages_info(getvariable('doc')) i LEFT JOIN f ON i.page = f.page
)
SELECT * FROM j;

-- L4 paragraphs: a body line starts a new one when > 14.5pt below the previous (line pitch is 13pt). Dehyphenate: a line ending in '-'
-- joins the next with no space (compounds broken at a margin lose their hyphen; accepted). first_ws is the first line's words+faces.
CREATE OR REPLACE TABLE pdf_paras AS
WITH d AS (
  SELECT sec_id, page, seq, n_words, text, ws, y0 - lag(y0) OVER ps AS dy
  FROM pdf_owned WHERE role = 'body' WINDOW ps AS (PARTITION BY sec_id, page ORDER BY seq)
),
p AS (
  SELECT *, sum(CASE WHEN dy IS NULL THEN 1 WHEN dy > 14.5 THEN 1 ELSE 0 END) OVER (PARTITION BY sec_id, page ORDER BY seq) AS para_id FROM d
)
SELECT sec_id, page, para_id, min(seq) AS seq, sum(n_words) AS pwords, list(ws ORDER BY seq)[1] AS first_ws,
       array_to_string(list(CASE WHEN ends_with(text, '-') THEN left(text, length(text) - 1) ELSE text || ' ' END ORDER BY seq), '') AS ptext
FROM p GROUP BY sec_id, page, para_id;

-- Key terms: tf-idf with sections as documents. A term needs tf >= 2 in its section, or to occur in a second section (drops one-off
-- flourish), and df <= n_sec / 10 (drops vocabulary shared across the book). No stoplist: idf does that work.
CREATE OR REPLACE TABLE pdf_terms AS
WITH t AS (
  SELECT sec_id, lower(trim(x, '.,;:()"“”‘’[]•!?*')) AS tok
  FROM (SELECT sec_id, unnest(string_split(ptext, ' ')) AS x FROM pdf_paras)
),
ok AS (SELECT sec_id, tok FROM t WHERE length(tok) >= 4 AND try_cast(tok AS DOUBLE) IS NULL AND NOT contains(tok, '’')),
tf AS (SELECT sec_id, tok, len(list(tok)) AS tf FROM ok GROUP BY sec_id, tok),
df AS (SELECT tok, len(list(sec_id)) AS df FROM tf GROUP BY tok),
sc AS (
  SELECT tf.sec_id, tf.tok, tf.tf * ln(pdf_secs.n_sec / df.df) AS score
  FROM tf JOIN df ON tf.tok = df.tok JOIN pdf_secs ON tf.sec_id = pdf_secs.sec_id
  WHERE greatest(tf.tf, df.df) >= 2 AND df.df <= pdf_secs.n_sec / 10
)
SELECT sec_id, list(tok ORDER BY score DESC, tok)[1:6] AS terms FROM sc GROUP BY sec_id;

CREATE OR REPLACE TABLE pdf_digest AS
WITH lead AS (
  SELECT sec_id, list(ptext ORDER BY seq)[1] AS para FROM pdf_paras WHERE pwords >= 12 GROUP BY sec_id
),
lead2 AS (
  SELECT sec_id, string_split(para, '. ') AS s,
         CASE WHEN length(s[1]) < 80 AND len(s) > 1 THEN s[1] || '. ' || s[2] ELSE s[1] END AS l
  FROM lead
),
stats AS (
  SELECT sec_id, sum(n_words) FILTER (WHERE role = 'body') AS body_words,
         len(list(text) FILTER (WHERE role = 'caption')) AS caption_lines,
         len(list(text) FILTER (WHERE role = 'table')) AS table_lines,
         len(list(text) FILTER (WHERE role = 'note')) AS note_lines
  FROM pdf_owned GROUP BY sec_id
),
figs AS (SELECT sec_id, len(list(text) FILTER (WHERE starts_with(text, 'Figure'))) AS n_figs FROM pdf_owned WHERE role = 'caption' GROUP BY sec_id),
ends AS (SELECT a.sec_id, min(b.seq) AS end_seq FROM pdf_secs a JOIN pdf_secs b ON b.seq > a.seq AND b.depth <= a.depth GROUP BY a.sec_id),
sub AS (
  SELECT a.sec_id, sum(coalesce(st.body_words, 0)) AS subtree_words
  FROM pdf_secs a LEFT JOIN ends e ON a.sec_id = e.sec_id
  JOIN pdf_secs c ON c.seq >= a.seq AND c.seq < coalesce(e.end_seq, 1e12)
  LEFT JOIN stats st ON c.sec_id = st.sec_id
  GROUP BY a.sec_id
)
SELECT s.sec_id, s.depth, s.num, s.page AS pdf_page, pg.printed_page, s.title,
       coalesce(st.body_words, 0) AS words, sub.subtree_words, figs.n_figs, st.note_lines,
       left(lead2.l, 200) AS lead, tm.terms
FROM pdf_secs s
LEFT JOIN pdf_pages pg ON s.page = pg.page
LEFT JOIN stats st ON s.sec_id = st.sec_id
LEFT JOIN figs ON s.sec_id = figs.sec_id
LEFT JOIN sub ON s.sec_id = sub.sec_id
LEFT JOIN lead2 ON s.sec_id = lead2.sec_id
LEFT JOIN pdf_terms tm ON s.sec_id = tm.sec_id;

-- Glossary: paragraphs of the section whose title contains the 'gloss' word; the term is the leading bold run, the definition the rest.
CREATE OR REPLACE TABLE pdf_glossary AS
WITH g AS (SELECT p.* FROM pdf_paras p JOIN pdf_secs s ON p.sec_id = s.sec_id WHERE contains(s.title, getvariable('gloss'))),
b AS (
  SELECT *, list_position(list_transform(first_ws, x -> contains(x.f, 'Bold')), false) AS fp FROM g
),
t AS (
  SELECT *, CASE WHEN fp = 0 THEN len(first_ws) ELSE fp - 1 END AS nlead FROM b
),
u AS (
  SELECT *, array_to_string(list_transform(first_ws[1:nlead], x -> x.w), ' ') AS term_raw FROM t WHERE nlead > 0
)
SELECT page, rtrim(term_raw, ':') AS term, trim(substr(ptext, length(term_raw) + 1)) AS definition, pwords FROM u ORDER BY page, seq;

-- Figures: caption lines from 'Figure' up to the next 'Figure'.
CREATE OR REPLACE TABLE pdf_figures AS
WITH c AS (SELECT sec_id, page, seq, text, starts_with(text, 'Figure') AS st FROM pdf_owned WHERE role = 'caption'),
d AS (SELECT *, sum(CASE WHEN st THEN 1 ELSE 0 END) OVER (ORDER BY seq) AS fig_id FROM c)
SELECT fig_id, page, sec_id, array_to_string(list(text ORDER BY seq), ' ') AS caption FROM d GROUP BY fig_id, page, sec_id;

-- Borderless tables from words. A block is table lines within 30pt of each other on a page; its first line is the header, whose
-- cells (words split at >= 10pt gaps) give the column edges; every word goes to the last edge at or left of it; a line with a
-- word in column 1 starts a row, any other line continues the previous row's cells (wrapped cells).
CREATE OR REPLACE TABLE pdf_tables AS
WITH tl AS (SELECT sec_id, page, seq, y0, ws FROM pdf_owned WHERE role = 'table'),
b0 AS (SELECT *, y0 - lag(y0) OVER (PARTITION BY page ORDER BY seq) AS dy FROM tl),
b1 AS (SELECT *, sum(CASE WHEN dy IS NULL THEN 1 WHEN dy > 30 THEN 1 ELSE 0 END) OVER (PARTITION BY page ORDER BY seq) AS block_id FROM b0),
hdr AS (
  SELECT page, block_id, list_transform(list_filter(list(ws ORDER BY seq)[1], x -> coalesce(x.gap, 99) >= 10), x -> x.x0) AS edges
  FROM b1 GROUP BY page, block_id
),
wd AS (
  SELECT b1.sec_id, b1.page, b1.block_id, b1.seq, unnest(b1.ws) AS w, hdr.edges
  FROM b1 JOIN hdr ON b1.page = hdr.page AND b1.block_id = hdr.block_id
),
wc AS (SELECT sec_id, page, block_id, seq, w.w AS word, w.x0 AS x0, len(list_filter(edges, e -> e <= w.x0 + 2)) AS c, len(edges) AS ncols FROM wd),
ln AS (
  SELECT sec_id, page, block_id, seq, min(c) AS first_c FROM wc GROUP BY sec_id, page, block_id, seq
),
rw AS (SELECT *, sum(CASE WHEN first_c <= 1 THEN 1 ELSE 0 END) OVER (PARTITION BY page, block_id ORDER BY seq) AS row_id FROM ln),
cell AS (
  SELECT wc.sec_id, wc.page, wc.block_id, rw.row_id, wc.c, wc.ncols, string_agg(wc.word, ' ' ORDER BY wc.seq, wc.x0) AS cell
  FROM wc JOIN rw ON wc.page = rw.page AND wc.block_id = rw.block_id AND wc.seq = rw.seq
  GROUP BY wc.sec_id, wc.page, wc.block_id, rw.row_id, wc.c, wc.ncols
)
, r AS (
  SELECT sec_id, page, block_id, row_id, ncols, list(struct_pack(k := c, v := cell)) AS entries
  FROM cell GROUP BY sec_id, page, block_id, row_id, ncols
)
SELECT sec_id, page, block_id, row_id, list_transform(range(1, ncols + 1), i -> coalesce(list_filter(entries, e -> e.k = i)[1].v, '')) AS cells FROM r;

-- The card: contents first (depth-nested, page + words), leads and terms on the sections, then the stats line. This is the low-token read.
CREATE OR REPLACE TABLE pdf_card AS
WITH info AS (SELECT * FROM pdf_info(getvariable('doc'))),
tb AS (SELECT sec_id, len(list(DISTINCT (page * 1000 + block_id))) AS n_tables FROM pdf_tables GROUP BY sec_id),
rows AS (
  SELECT d.sec_id, getvariable('doc') AS file,
         repeat('  ', d.depth - 1) || '- ' || d.title || ' · p' || d.printed_page || ' (pdf ' || d.pdf_page || ') · ' ||
         coalesce(CAST(d.subtree_words AS VARCHAR), '0') || 'w' ||
         CASE WHEN d.n_figs > 0 THEN ' · ' || CAST(d.n_figs AS VARCHAR) || ' fig' ELSE '' END ||
         CASE WHEN tb.n_tables > 0 THEN ' · ' || CAST(tb.n_tables AS VARCHAR) || ' tbl' ELSE '' END ||
         CASE WHEN d.depth <= 2 AND d.lead IS NOT NULL THEN chr(10) || repeat('  ', d.depth) || '> ' || d.lead ELSE '' END ||
         CASE WHEN d.terms IS NOT NULL THEN chr(10) || repeat('  ', d.depth) || '# ' || array_to_string(list_slice(d.terms, 1, CASE WHEN d.depth <= 2 THEN 6 ELSE 4 END), ', ') ELSE '' END AS md
  FROM pdf_digest d LEFT JOIN tb ON d.sec_id = tb.sec_id
)
SELECT '# ' || coalesce(info.title, 'Untitled') || coalesce(' — ' || info.author, '') || chr(10) ||
       '_' || CAST(info.page_count AS VARCHAR) || ' pp · ' || CAST(info.width AS VARCHAR) || '×' || CAST(info.height AS VARCHAR) || 'pt · digest of ' ||
       CAST(len(list(rows.sec_id)) AS VARCHAR) || ' headings · `> lead sentence`, `# tf-idf terms`_' || chr(10) || chr(10) ||
       '## Contents' || chr(10) || chr(10) || array_to_string(list(rows.md ORDER BY rows.sec_id), chr(10)) AS md
FROM rows JOIN info ON rows.file = info.file GROUP BY info.title, info.author, info.page_count, info.width, info.height;

-- Self-checks. Each is an independent witness that the reconstruction is faithful; a run that prints anything else is a defect.
-- 1. conservation: characters in the raw words equal characters in the lines (nothing dropped, nothing invented).
SELECT 'conserved_chars' AS check_name, len(list(DISTINCT n)) = 1 AS ok, list(src ORDER BY src) AS sources, list(n ORDER BY src) AS chars
FROM (SELECT 'raw_words' AS src, sum(length(word)) AS n FROM pdf_words UNION ALL SELECT 'lines', sum(length(replace(text, ' ', ''))) FROM pdf_lines);
-- 2. typography vs the file's own outline: headings found from font geometry alone against pdf_outline (normalised: lowercase, no spaces/colons).
--    unmatched should be 0 when the PDF has an outline; outline_total 0 or NULL means the PDF has none (nothing to compare).
WITH o AS (SELECT ord, title, replace(replace(lower(title), ' ', ''), ':', '') AS k FROM pdf_outline(getvariable('doc'))),
d AS (SELECT replace(replace(lower(title), ' ', ''), ':', '') AS k FROM pdf_digest GROUP BY k)
SELECT 'outline_agreement' AS check_name, len(list(o.ord)) AS outline_total, len(list(o.ord) FILTER (WHERE d.k IS NULL)) AS unmatched,
       list(o.title ORDER BY o.ord) FILTER (WHERE d.k IS NULL) AS unmatched_titles
FROM o LEFT JOIN d ON o.k = d.k;
-- 3. printed page: the PDF's /PageLabels against the running-header parse; disagreements should be 0.
SELECT 'label_vs_header' AS check_name, len(list(page)) AS disagree FROM pdf_pages WHERE printed_hdr IS NOT NULL AND label IS NOT NULL AND CAST(printed_hdr AS VARCHAR) <> label;

-- The card as a markdown file (contents-first, the way to hand a book to an LLM), then the digest as a grid.
.headers off
.mode list
.output card.md
SELECT md FROM pdf_card;
.output stdout
.headers on
.mode csv
SELECT * FROM pdf_digest ORDER BY sec_id;

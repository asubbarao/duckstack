-- Book digest: every PDF the glob matches -> a contents-first markdown card per file, from what each PDF declares itself.
-- Published `pdf` extension.   Run:  duckdb [file.duckdb] -f book-digest.sql   (edit the glob; writes cards.md)
--
-- Contents are the PDF's own outline (pdf_outline). A file with no outline takes them from pdf_chunks: a section starts
-- where the chunk heading changes. Each section lists the chunks pdf_chunks filed under that heading, with their pages.
-- Verified on dev 2026-10-09 over ~/Downloads/*.pdf: a 259-page book, a resume, a CI report, a form, a lab, two decks.
INSTALL pdf FROM community; LOAD pdf; INSTALL tera FROM community; LOAD tera;

CREATE OR REPLACE TABLE pdf_outline_rows AS FROM pdf_outline('/Users/aloksubbarao/Downloads/*.pdf');
CREATE OR REPLACE TABLE pdf_chunk_rows AS FROM pdf_chunks('/Users/aloksubbarao/Downloads/*.pdf');

-- One row per contents entry, with every chunk filed under it. Headings match ignoring case and spaces.
CREATE OR REPLACE TABLE pdf_sections AS
WITH chunk_heads AS (
    SELECT file, chunk_idx AS ord, 1 AS depth, heading AS title,
           heading IS DISTINCT FROM lag(heading) OVER (PARTITION BY file ORDER BY chunk_idx) AS starts
    FROM pdf_chunk_rows
),
contents AS (
    SELECT file, ord, depth, title FROM pdf_outline_rows
    UNION ALL BY NAME
    SELECT file, ord, depth, title FROM chunk_heads WHERE starts AND file NOT IN (SELECT file FROM pdf_outline_rows)
)
SELECT t.file, t.ord, t.depth, t.title,
       list({chunk_idx: c.chunk_idx, page_start: c.page_start, page_end: c.page_end, text: c.text} ORDER BY c.chunk_idx) AS chunks
FROM contents t
LEFT JOIN pdf_chunk_rows c ON c.file = t.file AND lower(translate(c.heading, ' ', '')) = lower(translate(t.title, ' ', ''))
GROUP BY t.file, t.ord, t.depth, t.title;

-- The cards: the contents tree, each entry with the pages its chunks span.
CREATE OR REPLACE TABLE pdf_card AS
SELECT file, tera_render($t$# {{ file }}

{% for s in sections %}{% for i in range(end=s.depth - 1) %}  {% endfor %}- {{ s.title }}{% if s.chunks[0].page_start %} · p{{ s.chunks[0].page_start }}–{{ s.chunks | last | get(key="page_end") }}{% endif %}
{% endfor %}$t$, json_object('file', parse_filename(file), 'sections', list(pdf_sections ORDER BY ord)), autoescape := false) AS md
FROM pdf_sections GROUP BY file;

COPY (SELECT md FROM pdf_card ORDER BY file) TO 'cards.md' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');

-- Book digest: every PDF the glob matches -> a contents-first markdown card per file, from what each PDF declares itself.
-- Published `pdf` extension.   Run:  duckdb :memory: -f book-digest.sql   (edit the glob in both reads; writes cards.md)
--
-- Contents are the PDF's own outline (pdf_outline). A file with no outline takes them from pdf_chunks: a section starts
-- where the chunk heading changes. Each entry shows the pages of the chunks pdf_chunks filed under its heading.
-- Verified 2026-10-17 over five PDFs in ~/Downloads (two with an outline, three from chunk headings).
INSTALL pdf FROM community;
LOAD pdf;
INSTALL tera FROM community;
LOAD tera;

COPY (
    WITH outline AS (
        FROM pdf_outline('/Users/aloksubbarao/Downloads/*.pdf')
    ), chunks AS (
        FROM pdf_chunks('/Users/aloksubbarao/Downloads/*.pdf')
    ), chunk_heads AS (
        SELECT file, chunk_idx AS ord, 1 AS depth, heading AS title,
               heading IS DISTINCT FROM lag(heading) OVER (PARTITION BY file ORDER BY chunk_idx) AS starts
        FROM chunks
    ), contents AS (
        SELECT file, ord, depth, title FROM outline
        UNION ALL BY NAME
        SELECT file, ord, depth, title FROM chunk_heads WHERE starts AND file NOT IN (SELECT file FROM outline)
    ), sections AS (            -- one row per contents entry; headings match ignoring case and spaces
        SELECT entry.file, entry.ord, entry.depth, entry.title,
               min(c.page_start) AS first_page, max(c.page_end) AS last_page
        FROM contents AS entry
        LEFT JOIN chunks AS c
            ON c.file = entry.file AND lower(translate(c.heading, ' ', '')) = lower(translate(entry.title, ' ', ''))
        GROUP BY entry.file, entry.ord, entry.depth, entry.title
    ), entries AS (             -- SQL computes every value; tera only fills holes
        SELECT file, ord,
               tera_render('{{ indent }}- {{ title }}{{ span }}',
                   json_object('indent', repeat('  ', depth - 1), 'title', title,
                               'span', coalesce(' · p' || first_page || '–' || last_page, '')),
                   autoescape := false) AS line
        FROM sections
    ), cards AS (
        SELECT file, tera_render(E'# {{ name }}\n\n{{ lines | join(sep="\n") }}\n',
                   json_object('name', parse_filename(file), 'lines', list(line ORDER BY ord)),
                   autoescape := false) AS md
        FROM entries GROUP BY file
    )
    SELECT md FROM cards ORDER BY file
) TO 'cards.md' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');

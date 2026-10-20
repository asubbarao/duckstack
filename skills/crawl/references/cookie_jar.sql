-- A login session in one query: the jar (which cookies the login set) and the carry (the next request with them).
-- The carry pipes the jar from one curl into the next (-c - prints it, -b - reads it from stdin), so no cookie value
-- is ever shell text and nothing needs quoting; a URL carries ' as %27. Commands are words; pipeline.tera joins them.
-- timeout 30 s per request; one worker; batch 1; no delay; no link following; no cache; one page per login.
-- For a form login add '-L', '-d <form>' to log_in.
-- Observed on dev 2026-10-20 (httpbin): x = 1 and x = a'b$c both came back unchanged, status 200; the jar receipt
-- had the x row after curl's three # comment lines. A value pasted into -H 'Cookie: …' broke on a'b$c (shell
-- exit 2), and Tera's autoescape is HTML encoding, so it sent a&#x27;b$c.
WITH intent AS (
    SELECT unnest(['https://httpbin.org/cookies/set?x=1', 'https://httpbin.org/cookies/set?x=a%27b%24c']) AS login_url,
           'https://httpbin.org/cookies' AS page_url,
           ['curl', '-sS', '--max-time 30', '-c -', '-o /dev/null', quote_literal(login_url)] AS log_in,
           ['curl', '-sS', '--max-time 30', '--fail', '-b -', quote_literal(page_url)] AS get_page,
           $o$, delim := '\t', header := false, null_padding := true, names := ['domain', 'include_subdomains', 'path', 'secure', 'expires', 'name', 'value']$o$ AS jar_columns
), steps AS (
    SELECT login_url, unnest([
        {step: 'jar',   reader: 'read_csv',  options: jar_columns, words: log_in},
        {step: 'carry', reader: 'read_text', options: '',          words: list_concat(log_in, ['|'], get_page)}
    ], max_depth := 2)
    FROM intent
), rendered AS (
    SELECT *, tera_render('pipeline.tera', c::JSON, autoescape := false,
           template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS executable_sql
    FROM steps AS c
), posted AS (
    SELECT login_url, step, executable_sql, array_agg(selfdispatch(executable_sql)) AS receipts FROM rendered GROUP BY ALL
)
SELECT login_url, step, executable_sql, receipt.status, receipt.body FROM posted CROSS JOIN UNNEST(receipts) AS t(receipt)
ORDER BY login_url, step;

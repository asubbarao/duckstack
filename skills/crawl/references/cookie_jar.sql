-- Cookie jar as a relation, then the cookie carried on the next request.
-- Observed on dev 2026-10-20 (httpbin): cookie_header = x=1, status 200, body {"cookies": {"x": "1"}}.
-- timeout 30 s per request; one worker; batch 1; no delay; no link following; no cache; one page.
-- The login url is the read_csv literal (a reader takes a literal); for a form login add -L -b '' -d '<form>'.
-- The header sits in shell single quotes: a cookie value may legally contain ', which would break it.
WITH intent AS (
    SELECT 'https://httpbin.org/cookies' AS target_url
), cookie_jar AS (
    SELECT * FROM read_csv($c$curl -sS --max-time 30 -c - -o /dev/null 'https://httpbin.org/cookies/set?x=1' |$c$,
        delim := '\t', header := false, null_padding := true,
        names := ['domain', 'include_subdomains', 'path', 'secure', 'expires', 'name', 'value'])
    WHERE name IS NOT NULL                          -- comment lines; comment := '#' would also skip #HttpOnly_ cookies
), cookie_headers AS (
    SELECT replace(domain, '#HttpOnly_', '') AS domain, string_agg(concat(name, '=', value), '; ' ORDER BY name) AS cookie_header
    FROM cookie_jar GROUP BY ALL
), carried_requests AS (
    SELECT h.*, i.target_url FROM cookie_headers AS h JOIN intent AS i ON starts_with(i.target_url, concat('https://', h.domain))
), rendered AS (
    SELECT *, tera_render($t$SELECT content FROM read_text($c$curl -sS --fail --max-time 30 -H 'Cookie: {{ cookie_header }}' '{{ target_url }}' |$c$)$t$,
           c::JSON, autoescape := false) AS executable_sql
    FROM carried_requests AS c
), posted AS (
    SELECT domain, cookie_header, target_url, array_agg(selfdispatch(executable_sql)) AS receipts FROM rendered GROUP BY ALL
)
SELECT domain, cookie_header, target_url, receipt.status, receipt.body FROM posted CROSS JOIN UNNEST(receipts) AS t(receipt);

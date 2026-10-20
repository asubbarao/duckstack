-- Cookie jar as a relation, then the cookie carried on the next request (verified on dev 2026-10-20:
-- cookie_header = x=1, status 200, body {"cookies": {"x": "1"}}).
-- timeout 30 s per request; one worker; batch 1; no delay; no link following; no cache; one page.
-- Swap the first url for the login (add -L -b '' and -d '<form>'), the second for the page behind it.
WITH cookie_jar AS (
    SELECT * FROM read_csv($c$curl -sS --max-time 30 -c - -o /dev/null 'https://httpbin.org/cookies/set?x=1' |$c$,
        delim = '\t', header = false, null_padding = true,
        names = ['domain', 'include_subdomains', 'path', 'secure', 'expires', 'name', 'value'])
    WHERE name IS NOT NULL                          -- comment lines; never comment = '#', it drops #HttpOnly_ cookies
), cookie_headers AS (
    SELECT replace(domain, '#HttpOnly_', '') AS domain, string_agg(name || '=' || value, '; ' ORDER BY name) AS cookie_header
    FROM cookie_jar GROUP BY ALL
), carried_requests AS (
    -- The header sits in shell single quotes: a cookie value may legally contain ', which would break it.
    SELECT domain, cookie_header, tera_render($t$SELECT content FROM read_text($c$curl -sS --fail --max-time 30 -H 'Cookie: {{ cookie_header }}' 'https://{{ domain }}/cookies' |$c$)$t$,
           json_object('domain', domain, 'cookie_header', cookie_header), autoescape := false) AS executable_sql
    FROM cookie_headers
), posted AS (
    SELECT domain, cookie_header, array_agg(selfdispatch(executable_sql)) AS receipts FROM carried_requests GROUP BY ALL
)
SELECT domain, cookie_header, receipt.status, receipt.body FROM posted CROSS JOIN UNNEST(receipts) AS t(receipt);

-- HTTP sessions as rows: any method (GET, POST, PATCH, PUT, DELETE), headers, raw bodies and one cookie jar per session.
-- A session row holds its requests in order; each request is a list of curl config options ({option, value}: url,
-- request, header, data-raw, …), so the caller writes curl's own words and the template holds no method logic.
-- network.tera sends a session's requests in order, each reading and rewriting the same jar, and answers one row per
-- request with the jar after it. Sessions are dispatched together and do not share jars. A step that needs a value
-- read from an earlier reply (a CSRF token) is a second session row, its jar seeded from the last reply's jar.
-- timeout 30 s per request; workers: one post per session, sessions sent together; batch: the session rows; no delay,
-- no retries; redirects followed (8 max), no link following, depth 0; no cache; one reply row per request.
-- POST is curl's default once data-raw is set, and a 302 after it becomes a GET (a form login). Add
-- {option: 'request', value: 'PATCH'} (or PUT, DELETE) for any other method. HEAD is not covered.
-- Observed on dev 2026-10-22 (httpbin, curl 8.7.1): session a's PATCH sent "session=a'b$c; second=2", the second cookie
-- set two requests earlier; the POST and PATCH bodies with O'Brien, "quoted", $HOME and $(whoami) arrived as text; the
-- DELETE answered 404 as its own row; session b, sent alongside, saw no cookies.
WITH sessions AS (
    SELECT 'a' AS session, '' AS jar, [
        [{option: 'url', value: 'https://httpbin.org/cookies/set?session=a%27b%24c'}],
        [{option: 'url', value: 'https://httpbin.org/post'}, {option: 'header', value: 'Content-Type: application/json'},
         {option: 'data-raw', value: $j${"name": "O'Brien", "note": "a \"quoted\" $HOME"}$j$}],
        [{option: 'url', value: 'https://httpbin.org/cookies/set?second=2'}],
        [{option: 'url', value: 'https://httpbin.org/patch'}, {option: 'request', value: 'PATCH'},
         {option: 'header', value: 'Content-Type: application/json'}, {option: 'data-raw', value: $j${"note": "$(whoami) stays text"}$j$}],
        [{option: 'url', value: 'https://httpbin.org/status/404'}, {option: 'request', value: 'DELETE'}]
    ] AS requests
    UNION ALL
    SELECT 'b', '', [[{option: 'url', value: 'https://httpbin.org/cookies'}]]
), rendered AS (
    SELECT *, tera_render('network.tera', c::JSON, autoescape := false,
               template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS executable_sql
    FROM sessions AS c
), dispatched AS (
    SELECT session, executable_sql, array_agg(selfdispatch(executable_sql)) AS receipts FROM rendered GROUP BY ALL
), replies AS (
    SELECT session, receipt.error AS dispatch_error, reply
    FROM dispatched CROSS JOIN UNNEST(receipts) AS r(receipt) CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(reply)
)
SELECT session, dispatch_error, reply ->> 'seq' AS seq, reply ->> 'status' AS status, reply ->> 'method' AS method,
       reply ->> 'url' AS url, reply ->> 'error' AS error, reply ->> 'body' AS body, reply ->> 'jar' AS jar
FROM replies ORDER BY session, seq::INTEGER;

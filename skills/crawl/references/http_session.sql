-- Any HTTP method — GET, POST, PATCH, PUT, DELETE — with headers, a raw body and a cookie jar, as rows. Each request is
-- one statement rendered by network.tera; its reply row carries the jar after the request. A stage that depends on a
-- login is the next atom/molecule pair, its rows joined to the previous stage's jar by session.
-- timeout 30 s per request; workers: one post per request, a stage's requests sent together; batch: the request rows;
-- no delay, no retries; redirects followed (8 max), no link following, depth 0; no cache; one reply per request.
-- POST keeps curl's own method so a 302 after a form login becomes a GET; any other method with a body is forced
-- with `request`. HEAD is not covered (curl would wait for a body). To resume a session, seed stage 1's jar with the
-- jar column of an earlier reply instead of ''.
-- Observed on dev 2026-10-21 (httpbin, curl 8.7.1): the cookie session=a'b$c set during stage 1's redirect reached the
-- POST, the PATCH and the GET unchanged; the bodies O'Brien, "quoted", $HOME and $(whoami) arrived as text; a DELETE
-- answered 404 and a missing host answered status 0 with curl's "Could not resolve host", each as its own row.
WITH requests AS (
    SELECT unnest([
        {session: 'httpbin', stage: 1, request: 'log in', method: 'GET', url: 'https://httpbin.org/cookies/set?session=a%27b%24c',
         headers: []::VARCHAR[], body: NULL::VARCHAR},
        {session: 'httpbin', stage: 2, request: 'create', method: 'POST', url: 'https://httpbin.org/post',
         headers: ['Content-Type: application/json', 'X-Note: it''s "quoted"'], body: $j${"name": "O'Brien", "note": "a \"quoted\" $HOME"}$j$},
        {session: 'httpbin', stage: 2, request: 'update', method: 'PATCH', url: 'https://httpbin.org/patch',
         headers: ['Content-Type: application/json'], body: $j${"note": "patched; $(whoami) stays text"}$j$},
        {session: 'httpbin', stage: 2, request: 'read cookies', method: 'GET', url: 'https://httpbin.org/cookies',
         headers: []::VARCHAR[], body: NULL::VARCHAR}
    ], max_depth := 2)
), curl_configs AS (
    SELECT *, list_transform(list_filter(list_concat([
               {option: 'url', value: url},
               {option: 'request', value: CASE WHEN method = 'POST' THEN NULL WHEN method = 'GET' AND body IS NULL THEN NULL ELSE method END},
               {option: 'data-raw', value: CASE WHEN method = 'POST' AND body IS NULL THEN '' ELSE body END}
           ], list_transform(headers, h -> {option: 'header', value: h})), o -> o.value IS NOT NULL),
           o -> concat(o.option, ' = ', to_json(o.value))) AS config_lines
    FROM requests
), stage1_dispatch AS (      -- atom: the login, with an empty jar
    SELECT *, tera_render('network.tera', json_object('config_lines', config_lines, 'jar', ''), autoescape := false,
               template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS executable_sql
    FROM curl_configs WHERE stage = 1
), stage1_receipts AS (
    SELECT * EXCLUDE (config_lines), array_agg(selfdispatch(executable_sql)) AS receipts FROM stage1_dispatch GROUP BY ALL
), stage1_replies AS (       -- molecule: network.tera answers one row, so a failed request keeps its row with a NULL reply
    SELECT * EXCLUDE (receipts), TRY_CAST(receipt.body AS JSON[])[1] AS reply
    FROM stage1_receipts CROSS JOIN UNNEST(receipts) AS r(receipt)
), stage1_jars AS (
    SELECT *, reply ->> 'status' AS status, reply ->> 'jar' AS jar FROM stage1_replies
), stage2_dispatch AS (      -- atom: each later request carries its session's jar
    SELECT cc.*, s1.jar AS jar_in,
           tera_render('network.tera', json_object('config_lines', cc.config_lines, 'jar', s1.jar), autoescape := false,
               template_path := '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/templates/*.tera') AS executable_sql
    FROM curl_configs cc JOIN stage1_jars s1 USING (session) WHERE cc.stage = 2
), stage2_receipts AS (
    SELECT * EXCLUDE (config_lines), array_agg(selfdispatch(executable_sql)) AS receipts FROM stage2_dispatch GROUP BY ALL
), stage2_replies AS (       -- molecule
    SELECT * EXCLUDE (receipts), TRY_CAST(receipt.body AS JSON[])[1] AS reply
    FROM stage2_receipts CROSS JOIN UNNEST(receipts) AS r(receipt)
), stage2_jars AS (
    SELECT *, reply ->> 'status' AS status, reply ->> 'jar' AS jar FROM stage2_replies
)
SELECT session, stage, request, method, url, status, receipt.error AS dispatch_error, reply, jar FROM stage1_jars
UNION ALL BY NAME
SELECT session, stage, request, method, url, status, receipt.error AS dispatch_error, reply, jar FROM stage2_jars
ORDER BY session, stage, request;

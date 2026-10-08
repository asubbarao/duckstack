-- Luna CI-fix webhook on the existing QuackAPI (approved by Alok 2026-10-02). LOAD quackapi and shellfs before this file.
-- POST /luna/ci-fix  JSON {"repo": "owner/name", "number": 18, "source": "<sender>", "jobs": ["<job url>"], "task": "<text>"}
-- repo and number are required. Any sender uses this one contract: the DuckDB cron (luna_ci.sql), Slack, a GitHub
-- webhook relay, or another agent's curl. The route only names the request and hands the body (base64, so it never
-- becomes SQL text) to luna_ci/handler.sql, posted to /sql; the handler decides, records and launches.
-- rid is deterministic per request (now() is fixed within a statement), so the alias can be reused safely.
CREATE OR REPLACE ROUTE luna_ci_fix POST '/luna/ci-fix' AS
SELECT rid, (receipt ->> '$.status')::INTEGER AS status, receipt ->> '$.body' AS result
FROM (SELECT strftime(now(), '%Y%m%dT%H%M%S') || '-' || left(md5($body::VARCHAR || epoch_us(now())::VARCHAR), 8) AS rid,
             http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'},
                 json_object('sql', replace(replace(content, '@RID', rid), '@BODY64', to_base64(encode($body::VARCHAR))))) AS receipt
      FROM read_text('/Users/aloksubbarao/duckdb-skills/server/luna_ci/handler.sql'));

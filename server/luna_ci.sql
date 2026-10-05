-- luna_ci.sql: the cron side of the Luna CI-fix webhook. Hourly, two minutes after open_prs.sql (cron.sql), it posts one
-- body per PR whose CI is red because of the PR itself to POST /luna/ci-fix (routes/luna_ci.sql), the same contract
-- every other sender uses. The handler (luna_ci/handler.sql) dedupes by head sha and caps running Lunas at 5.
CREATE TABLE IF NOT EXISTS luna_ci_cron_receipts (posted_at TIMESTAMPTZ, repo VARCHAR, number INTEGER, receipt JSON);
INSERT INTO luna_ci_cron_receipts BY NAME
SELECT now() AS posted_at, repo, number,
       http_post('http://127.0.0.1:9495/luna/ci-fix', MAP {'Content-Type': 'application/json'},
                 json_object('repo', repo, 'number', number, 'source', 'cron:open_prs')) AS receipt
FROM open_prs_waiting
WHERE whose_move = 'mine: CI red' AND NOT starts_with(repo, 'inframe-risk/')

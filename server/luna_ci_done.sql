-- luna_ci_done.sql: close the Luna CI-fix runs that POST /luna/ci-fix started. Every minute (cron.sql): a run whose
-- out.md exists gets finished_at and report and is posted to the agent inbox (source luna_ci, kind ci_fix.done).
-- A run whose process is gone with no out.md (killed, crashed), or whose launch printed no pid within 10 minutes,
-- is closed with that reason, so it stops holding one of the 5 slots.
CREATE TABLE IF NOT EXISTS luna_ci_dispatch (rid VARCHAR, source VARCHAR, repo VARCHAR, number INTEGER, head_owner VARCHAR,
    head_branch VARCHAR, head_sha VARCHAR, failing_jobs JSON, task VARCHAR, bare VARCHAR, worktree VARCHAR, run_dir VARCHAR,
    out_path VARCHAR, brief VARCHAR, run_script VARCHAR, pid BIGINT, started_at TIMESTAMPTZ, finished_at TIMESTAMPTZ,
    report VARCHAR, PRIMARY KEY (repo, number, head_sha));
CREATE OR REPLACE TABLE luna_ci_finished AS
WITH open_runs AS (SELECT * FROM luna_ci_dispatch WHERE finished_at IS NULL),
outs AS (SELECT filename AS out_path, content
         FROM read_text('/Users/aloksubbarao/.duck/luna_runs/parent_system=devserver/parent=luna_ci/*/out.md')),
alive AS (SELECT pid, true AS is_alive FROM agents.host_processes())
SELECT o.repo, o.number, o.source, o.head_branch, o.head_sha, o.run_dir, o.out_path, o.pid, o.started_at,
       CASE WHEN outs.content IS NOT NULL THEN outs.content
            WHEN o.pid IS NULL AND o.started_at < now() - INTERVAL 10 MINUTE THEN 'Launch failed: no pid recorded within 10 minutes; see luna_ci_receipts (step launch).'
            WHEN o.pid IS NOT NULL AND alive.is_alive IS NULL THEN 'Run died: pid ' || o.pid || ' is gone and out.md was never written; see ' || o.run_dir || '/prep.log and run.log.'
       END AS run_report
FROM open_runs AS o LEFT JOIN outs USING (out_path) LEFT JOIN alive USING (pid)
WHERE run_report IS NOT NULL;
UPDATE luna_ci_dispatch SET finished_at = now(), report = f.run_report
FROM luna_ci_finished AS f
WHERE luna_ci_dispatch.out_path = f.out_path AND luna_ci_dispatch.finished_at IS NULL;
CREATE TABLE IF NOT EXISTS luna_ci_inbox_receipts (posted_at TIMESTAMPTZ, repo VARCHAR, number INTEGER, head_sha VARCHAR, receipt JSON);
INSERT INTO luna_ci_inbox_receipts BY NAME
SELECT now() AS posted_at, repo, number, head_sha,
       http_post('http://127.0.0.1:9495/inbox', MAP {'Content-Type': 'application/json'},
                 json_object('source', 'luna_ci', 'kind', 'ci_fix.done', 'repo', repo, 'number', number,
                             'requested_by', source, 'head_branch', head_branch, 'head_sha', head_sha, 'run_dir', run_dir,
                             'pid', pid, 'started_at', started_at, 'report', run_report)) AS receipt
FROM luna_ci_finished

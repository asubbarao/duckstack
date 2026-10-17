-- CI events. A Claude Code PostToolUse hook (async, in ~/.claude/settings.json) posts one JSON object to
-- POST /ci/event when a session pushes, opens a PR, watches or views a run, or edits a file under .github/:
--   {at, session_id, cwd, dir, remote, branch, tool_name, command, file_path}
-- The route only enqueues it. The queue row in quackapi_jobs (queue 'ci') is the event's record and is kept after it
-- is handled (status 'done'), so no table of our own is needed. Queue rows survive restarts and CREATE OR REPLACE QUEUE.
CREATE SCHEMA IF NOT EXISTS ci;
-- visibility_timeout: an event taken by a run that never acknowledges it comes back after 10 minutes, at most 3 times.
CREATE OR REPLACE QUEUE ci WITH (visibility_timeout=600, max_attempts=3);
CREATE OR REPLACE ROUTE ci_event POST '/ci/event' STATUS 202 AS SELECT quackapi_enqueue('ci', $body::JSON) AS id;

-- ci.events: every event, newest first, with the GitHub repository as owner/name. The remote is
-- git@github.com:owner/name.git or https://github.com/owner/name.git; with ':' made a '/', the last folder is the owner
-- and the file name without '.git' is the repository. An ssh alias (git@github-asubbarao:owner/name.git) reads the same way; a remote not on GitHub has no repo.
CREATE OR REPLACE VIEW ci.events AS
SELECT id, status, attempts, created_at, payload::JSON AS event,
       event ->> 'remote' AS remote, event ->> 'branch' AS branch, event ->> 'tool_name' AS tool_name,
       event ->> 'command' AS command, event ->> 'file_path' AS file_path,
       replace(remote, ':', '/') AS remote_path,
       CASE WHEN contains(remote, 'github') THEN parse_filename(parse_dirpath(remote_path)) || '/' || parse_filename(remote_path, true) END AS repo
FROM quackapi_jobs
WHERE queue = 'ci'
ORDER BY id DESC;

-- ci.requested: what the running measurement is for, one row per GitHub repository and branch. These are the events
-- the cron below has taken and not yet acknowledged. ci_measure.sql reads this view to know which runs to measure.
CREATE OR REPLACE VIEW ci.requested AS
SELECT repo, branch, list(id ORDER BY id) AS event_ids, max(created_at) AS last_event_at
FROM ci.events
WHERE status = 'running' AND repo IS NOT NULL AND branch <> ''
GROUP BY repo, branch;

-- Every minute: take up to 100 waiting events. If there are any, post ci_measure.sql's current text to /sql once (an
-- edit to that file is live on the next run, no restart). The taken events stay 'running' while it runs, which is
-- what ci.requested shows it. Acknowledge them when the post succeeded; a failed post leaves them to come back.
-- No waiting events: the GROUP BY has no group, so nothing is posted.
SELECT cron($program$
WITH taken AS (
    SELECT getenv('HOME') || '/.duck/deploy/server/ci_measure.sql' AS filename,
           list({id: id, generation: delivery_generation}) AS jobs
    FROM quackapi_dequeue('ci', 100)
    GROUP BY filename
), statements AS (
    SELECT t.jobs, m.content AS sql
    FROM taken t JOIN read_text(getenv('HOME') || '/.duck/deploy/server/ci_measure.sql') m USING (filename)
), posted AS (
    SELECT array_agg({jobs: jobs, receipt: selfdispatch(sql)}) AS receipts FROM statements
), checked AS (
    SELECT r.jobs, r.receipt.status AS status, r.receipt.body AS body,
           status = 200 AND NOT coalesce(json_exists(try_cast(body AS JSON), '$.detail'), false) AS succeeded
    FROM posted CROSS JOIN UNNEST(receipts) AS t(r)
)
SELECT j.id, c.status, c.succeeded,
       CASE WHEN c.succeeded THEN quackapi_ack('ci', j.id, j.generation) END AS acknowledged
FROM checked c CROSS JOIN UNNEST(c.jobs) AS u(j);
$program$, '45 * * * * *') AS job;


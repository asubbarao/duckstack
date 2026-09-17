-- @ext: httpfs
-- @rev: 827222f (core, DuckDB 1.5.5); loaded on dev and locally
-- @verified: 2026-09-17 — GitHub leg ran end to end (89 runs / 100 PRs typed straight from the API, landed on dev)
-- @functions: read_json over https://, read_text over https://, CREATE SECRET (TYPE http, EXTRA_HTTP_HEADERS), CREATE PERSISTENT SECRET
-- @needs: a bearer token per API in the environment; nothing else
-- @tags: api, rest, github, sentry, slack, etl, window, 1 hour, 1 day, backfill, bearer, secret
-- @summary: Any GET JSON API is a table: the reader types the response, an http secret carries the
--   headers for a URL prefix. Windows are '-1h' / '-1d' / a backfill day, expressed as the API's own
--   time parameter. POST APIs (Linear GraphQL) are in ext/http_client.sql.
LOAD httpfs;

-- One secret per API host; scope is a literal prefix match. Persistent = written 0600 to secret_directory
-- (~/.duck/secrets on this machine) and reloaded by the dev server at its next start.
CREATE OR REPLACE SECRET github_api (TYPE http,
  EXTRA_HTTP_HEADERS MAP {'Authorization': 'Bearer ' || getenv('GITHUB_TOKEN'), 'Accept': 'application/vnd.github+json',
                          'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'inframe-duckstack'},
  SCOPE 'https://api.github.com/');
CREATE OR REPLACE SECRET sentry_api (TYPE http, EXTRA_HTTP_HEADERS MAP {'Authorization': 'Bearer ' || getenv('SENTRY_AUTH_TOKEN')}, SCOPE 'https://us.sentry.io/api/0/');
CREATE OR REPLACE SECRET slack_api  (TYPE http, EXTRA_HTTP_HEADERS MAP {'Authorization': 'Bearer ' || getenv('SLACK_BOT_TOKEN')},  SCOPE 'https://slack.com/api/');

-- The window, once. '1 hour' for the hourly pull, '1 day' for the daily; a backfill sets both ends.
SET VARIABLE win = INTERVAL 1 DAY;
SET VARIABLE win_start = now() - getvariable('win');
SET VARIABLE win_end   = now();

-- GitHub: a JSON object with an array field → unnest; a top-level array → rows directly.
--   Runs are the handle duck_hunt needs (gh api …/runs/<id>/logs).
CREATE TEMP TABLE gh_runs AS
SELECT r.* FROM (SELECT unnest(workflow_runs) AS r
  FROM read_json('https://api.github.com/repos/inframe-risk/inframe/actions/runs?per_page=100&created=>=' || getvariable('win_start')::DATE::VARCHAR));
CREATE TEMP TABLE gh_pulls AS
SELECT * FROM read_json('https://api.github.com/repos/inframe-risk/inframe/pulls?state=all&sort=updated&direction=desc&per_page=100')
WHERE updated_at >= getvariable('win_start')::TIMESTAMP;

-- Sentry: statsPeriod is the window ('1h', '24h', '7d'); events for a backfill day use start/end ISO.
CREATE TEMP TABLE sentry_issues AS
SELECT * FROM read_json('https://us.sentry.io/api/0/organizations/inframe-risk/issues/?statsPeriod=24h&limit=100', records := true);
-- per-issue events, one issue per row, the id assembled from the row (LATERAL keeps it one query)
SELECT i.shortId, e.* FROM sentry_issues i,
  LATERAL (SELECT * FROM read_json('https://us.sentry.io/api/0/issues/' || i.id || '/events/?full=false', records := true)) e LIMIT 50;

-- Slack: oldest/latest are epoch seconds; one channel per call; bot posts (Sentry, GitHub) keep bot_id/attachments/blocks whole.
CREATE TEMP TABLE slack_msgs AS
SELECT c.channel_id, m.*
FROM (VALUES ('C0AJV462T4K'), ('C0AV2B62L68'), ('C0BKMLQ6URE'), ('C0BMT1GD4CS'), ('C0BMW10645R')) c(channel_id),
     LATERAL (SELECT unnest(messages) AS m
              FROM read_json('https://slack.com/api/conversations.history?channel=' || c.channel_id || '&limit=200'
                             || '&oldest=' || epoch(getvariable('win_start'))::BIGINT::VARCHAR
                             || '&latest=' || epoch(getvariable('win_end'))::BIGINT::VARCHAR)) h;
-- thread replies for messages that have them: conversations.replies?channel=&ts=<thread_ts>, same LATERAL shape.

-- Backfill = the same statements with win_start/win_end set to a day, in a loop of days that a
-- self-dispatch query drives (ext/quackapi.sql): one row per day → one POST per day → rows landed.

-- Pagination: GitHub `page=N`, Sentry the Link header (not visible to read_json — use ext/http_client.sql http_head
-- or bound the window so one page suffices), Slack `cursor=` from response_metadata.next_cursor.
-- Errors: a 4xx/5xx raises from read_json; HTTP 200 with {"ok":false,"error":"…"} from Slack does not — check `ok`.

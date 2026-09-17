-- @ext: cronjob
-- @rev: community, DuckDB 1.5.5; loaded on dev (setup.sql)
-- @verified: 2026-09-17 — surface listed in setup.sql (cron(), cron_jobs(), cron_delete()); jobs not yet registered for the feeds
-- @functions: cron, cron_jobs, cron_delete
-- @needs: a long-lived process (the dev quack server); persistent http secrets for the pulls it runs
-- @tags: schedule, hourly, daily, refresh, etl, dagster later
-- @summary: The schedule lives on the server as rows. One job per feed and window; the SQL is the same
--   statement the artifact runs by hand, so hand-run and scheduled never drift.
-- cron(schedule VARCHAR, query VARCHAR) -> job id  ;  cron_jobs() lists  ;  cron_delete(id)
-- Jobs are session state on the server: re-registered by setup.sql or by this file after a launchd restart.

-- hourly: the '1 hour' window
SELECT cron('7 * * * *', $$INSERT INTO raw_slack_messages SELECT now(), c.channel_id, m.* FROM (VALUES ('C0AJV462T4K'), ('C0AV2B62L68')) c(channel_id), LATERAL (SELECT unnest(messages) AS m FROM read_json('https://slack.com/api/conversations.history?channel=' || c.channel_id || '&limit=200&oldest=' || epoch(now() - INTERVAL 1 HOUR)::BIGINT::VARCHAR)) h WHERE (c.channel_id, m.ts) NOT IN (SELECT channel_id, ts FROM raw_slack_messages)$$);

-- daily: the '1 day' window, 06:10 UTC
SELECT cron('10 6 * * *', $$INSERT INTO raw_github_workflow_runs SELECT now(), r.* FROM (SELECT unnest(workflow_runs) AS r FROM read_json('https://api.github.com/repos/inframe-risk/inframe/actions/runs?per_page=100&created=>=' || (current_date - 1)::VARCHAR)) WHERE r.id NOT IN (SELECT id FROM raw_github_workflow_runs)$$);
SELECT cron('12 6 * * *', $$INSERT INTO raw_sentry_issues SELECT now(), * FROM read_json('https://us.sentry.io/api/0/organizations/inframe-risk/issues/?statsPeriod=24h&limit=100', records := true)$$);

FROM cron_jobs();
-- SELECT cron_delete(<id>);

-- Dagster later replaces these three lines with assets keyed on the same windows; the tables and statements stay.

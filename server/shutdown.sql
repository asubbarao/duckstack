-- cronjob 0571110 holds its mutex through Query: deletion waits for in-flight work.
-- setup.sql recreates these idempotent jobs; never close stdin while one can still run.
SELECT cron_delete(job_id) AS removed FROM cron_jobs() LIMIT ALL;
SELECT CASE WHEN EXISTS (FROM cron_jobs()) THEN error('shutdown: scheduled jobs remain')
            ELSE 'drained' END AS scheduler;

-- Posted to 9495 by the launchd wrapper's TERM trap; the body runs on a 9494 worker, so every statement here reaches dev.
-- otlp_stop() seals the buffered rows into the lake and joins its workers; with no lake attached it stops nothing.
FROM otlp_stop();
-- cronjob 0571110 holds its mutex through Query: deletion waits for in-flight work.
SELECT cron_delete(job_id) AS removed FROM cron_jobs() LIMIT ALL;
SELECT CASE WHEN EXISTS (FROM cron_jobs()) THEN error('shutdown: scheduled jobs remain')
            ELSE 'drained' END AS scheduler;
-- Close both ports, 9495 last because this request answers through it. Neither stop waits for requests already
-- running (each joins its workers on a detached thread), so the wrapper waits for their sockets before closing stdin.
FROM quack_stop('quack:localhost:9494');
FROM quackapi_stop();

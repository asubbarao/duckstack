-- Run the whole catalog body in cron, without a short-lived HTTP wrapper.
-- This prevents a fetch that outlives its caller from overlapping the next tick.
SELECT cron_delete(job_id) FROM cron_jobs()
WHERE CASE WHEN starts_with(query,'-- Refresh extension catalog raw.') THEN true
ELSE contains(query,'/server/ext_catalog.sql') END;
SELECT cron('-- Refresh extension catalog raw.' || chr(10) || content,'10 * * * * *')
FROM read_text(getvariable('server_dir') || '/server/ext_catalog.sql')
WHERE nullif(getenv('DUCKSTACK_CI'), '') IS DISTINCT FROM '1';

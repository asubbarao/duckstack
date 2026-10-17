-- Dev only (agents' clients do not read this file). Every 15 minutes, and once at boot: append host_processes to
-- ~/.duck/logs/host/processes/day=…/ as Parquet, and kill every process group an agent spawned (host_processes.spawned_by)
-- that has run 10 minutes or more. An orphaned group whose first process is an app or system helper is kept.
-- Rows of a killed group carry killed = true and the kill's receipt; host_process_history reads them all.
WITH program AS (
    SELECT $reap$
COPY (
WITH procs AS (
    FROM host_processes
), keep AS (
    SELECT '%.app/Contents/%' AS pattern UNION ALL SELECT '/System/%' UNION ALL SELECT '/usr/%' UNION ALL
    SELECT '/Library/%' UNION ALL SELECT '/opt/homebrew/Cellar/podman/%'
), groups AS (
    SELECT pgid, arg_min(spawned_by, started_at) AS spawned_by, arg_min(args, started_at) AS root_args, max(age_s) AS age_s
    FROM procs WHERE pgid > 1 GROUP BY pgid
), doomed AS (
    SELECT g.pgid FROM groups g ANTI JOIN keep k ON g.spawned_by = 'orphan' AND g.root_args LIKE k.pattern
    WHERE g.spawned_by IS NOT NULL AND g.age_s >= 600
), killed AS (
    SELECT pgid, selfdispatch(printf($s$SELECT content FROM read_lines('kill -TERM -- -%d 2>&1; echo exit=$? |')$s$, pgid)) AS receipt
    FROM doomed
)
SELECT p.*, d.pgid IS NOT NULL AS killed, d.receipt.body AS kill_receipt, strftime(p.observed_at, '%Y-%m-%d') AS day
FROM procs p LEFT JOIN killed d USING (pgid)
) TO '~/.duck/logs/host/processes' (FORMAT parquet, PARTITION_BY (day), APPEND, FILENAME_PATTERN 'snap_{uuid}');
$reap$ AS sql
), posted AS (
    SELECT sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY sql
)
SELECT cron(sql, '0 */15 * * * *') AS job, r.status FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

CREATE OR REPLACE VIEW host_process_history AS
FROM read_parquet('~/.duck/logs/host/processes/*/*.parquet', hive_partitioning := true, union_by_name := true);

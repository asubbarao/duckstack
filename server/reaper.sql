-- Dev only (agents' clients do not read this file). Every 5 minutes, and once at boot: append host_processes to
-- ~/.duck/logs/processes/day=…/ and host_memory to ~/.duck/logs/memory/day=…/ as Parquet, and kill every process group
-- an agent spawned (host_processes.spawned_by) that has run 10 minutes or more. An orphaned group whose first process
-- is an app or system helper is kept. A group already killed in the last 30 minutes and still alive gets KILL, not TERM.
-- Rows of a killed group carry killed = true, kill_signal and the kill's receipt.
CREATE OR REPLACE VIEW host_process_history AS
FROM read_parquet('~/.duck/logs/processes/*/*.parquet', hive_partitioning := true, union_by_name := true);

CREATE OR REPLACE VIEW host_memory_history AS
FROM read_parquet('~/.duck/logs/memory/*/*.parquet', hive_partitioning := true, union_by_name := true);

WITH program AS (
    SELECT $reap$
COPY (
WITH procs AS (
    FROM host_processes
), keep AS (
    SELECT '%.app/Contents/%' AS pattern UNION ALL SELECT '/System/%' UNION ALL SELECT '/usr/%' UNION ALL
    SELECT '/Library/%' UNION ALL SELECT '/opt/homebrew/Cellar/podman/%'
), groups AS (
    SELECT pgid, arg_min(spawned_by, started_at) AS spawned_by, arg_min(args, started_at) AS root_args, max(age_s) AS age_s,
           max(observed_at) AS observed_at
    FROM procs WHERE pgid > 1 GROUP BY pgid
), recent_kills AS (   -- observed_at is local wall time from ps; dev's own clock functions run in UTC
    SELECT DISTINCT g.pgid FROM groups g
    JOIN host_process_history h ON h.pgid = g.pgid AND h.killed AND h.observed_at >= g.observed_at - INTERVAL 30 MINUTE
), doomed AS (
    SELECT g.pgid, CASE WHEN r.pgid IS NULL THEN 'TERM' ELSE 'KILL' END AS kill_signal
    FROM groups g ANTI JOIN keep k ON g.spawned_by = 'orphan' AND g.root_args LIKE k.pattern
    LEFT JOIN recent_kills r ON r.pgid = g.pgid
    WHERE g.spawned_by IS NOT NULL AND g.age_s >= 600
), killed AS (
    SELECT pgid, kill_signal,
           selfdispatch(printf($s$SELECT content FROM read_lines('kill -%s -- -%d 2>&1; echo exit=$? |')$s$, kill_signal, pgid)) AS receipt
    FROM doomed
)
SELECT p.*, d.pgid IS NOT NULL AS killed, d.kill_signal, d.receipt.body AS kill_receipt, strftime(p.observed_at, '%Y-%m-%d') AS day
FROM procs p LEFT JOIN killed d USING (pgid)
) TO '~/.duck/logs/processes' (FORMAT parquet, PARTITION_BY (day), APPEND, FILENAME_PATTERN 'snap_{uuid}');
COPY (SELECT *, strftime(observed_at, '%Y-%m-%d') AS day FROM host_memory)
TO '~/.duck/logs/memory' (FORMAT parquet, PARTITION_BY (day), APPEND, FILENAME_PATTERN 'snap_{uuid}');
$reap$ AS sql
), posted AS (
    SELECT sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY sql
)
SELECT cron(sql, '0 */5 * * * *') AS job, r.status FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

-- Dev only (agents' clients do not read this file). Every 5 minutes, and once at boot, in one shell line: TERM, five
-- seconds, KILL. Kills every process group host_processes marks reap, and every command a session's own DuckDB
-- (server/client.sql) has run for over 3 minutes: one stuck shellfs command blocks every later call to that session's
-- duck, and the command shares duck's group, so it is killed by pid. Nothing to kill, no command.
WITH program AS (
    SELECT $reap$
WITH targets AS (   -- a group is killed as -pgid, a duck command by its pid
    SELECT list_distinct(list(CASE WHEN reap THEN '-' || pgid
                                   WHEN contains(parent_args, '/server/client.sql') AND age_s >= 180 THEN pid::VARCHAR END)) AS ids
    FROM host_processes
), rendered AS (
    SELECT tera_render($t$SELECT content FROM read_lines($k$kill -TERM -- {{ ids | join(sep=" ") }} 2>&1; sleep 5; kill -KILL -- {{ ids | join(sep=" ") }} 2>/dev/null; echo reaped |$k$)$t$,
                       targets::JSON, autoescape := false) AS sql
    FROM targets WHERE len(ids) > 0
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.status FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);
$reap$ AS sql
), posted AS (
    SELECT sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY sql
)
SELECT cron(sql, '0 */5 * * * *') AS job, r.status FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

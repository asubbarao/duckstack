-- Dev only (agents' clients do not read this file). Every 5 minutes, and once at boot: kill every process group
-- host_processes marks reap, in one shell line: TERM, five seconds, KILL. No groups to reap, no command.
WITH program AS (
    SELECT $reap$
WITH targets AS (
    SELECT list(DISTINCT '-' || pgid) AS groups FROM host_processes WHERE reap
)
SELECT selfdispatch(tera_render($t$SELECT content FROM read_lines($k$kill -TERM -- {{ groups | join(sep=" ") }} 2>&1; sleep 5; kill -KILL -- {{ groups | join(sep=" ") }} 2>/dev/null; echo reaped |$k$)$t$,
                                json_object('groups', groups), autoescape := false)).status AS kill_status
FROM targets WHERE len(groups) > 0;
$reap$ AS sql
), posted AS (
    SELECT sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY sql
)
SELECT cron(sql, '0 */5 * * * *') AS job, r.status FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

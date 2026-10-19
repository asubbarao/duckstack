-- Dev only (agents' clients do not read this file). Every 5 minutes, and once at boot: kill every process group
-- host_processes marks reap, in one shell line: TERM, five seconds, KILL. No groups to reap, no command.
WITH program AS (
    SELECT $reap$
WITH targets AS (
    SELECT list(DISTINCT pgid) AS groups FROM host_processes WHERE reap
), rendered AS (
    SELECT tera_render($t$SELECT content FROM read_lines($k$kill -TERM -- -{{ groups | join(sep=" -") }} 2>&1; sleep 5; kill -KILL -- -{{ groups | join(sep=" -") }} 2>/dev/null; echo reaped |$k$)$t$,
                       targets::JSON, autoescape := false) AS sql
    FROM targets WHERE len(groups) > 0
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.status FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);
$reap$ AS sql
), posted AS (
    SELECT sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY sql
)
SELECT cron(sql, '0 */5 * * * *') AS job, r.status FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

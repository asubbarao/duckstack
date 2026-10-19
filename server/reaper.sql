-- Dev only (agents' clients do not read this file). Every 5 minutes, and once at boot: write every host_processes row
-- with a kill_id (processes.sql), every column, to ~/.duck/logs/reaped-<UTC time>.json, read the kill_ids back
-- from that file, and kill them (-pgid, which kill reads as the whole group, or a pid alone) in one shell line: TERM,
-- five seconds, KILL. Each step is its own post built from the previous receipt, so what is killed is what was dumped.
-- Nothing to kill, no file and no command.
WITH program AS (
    SELECT $reap$
WITH targets AS (
    SELECT strftime(timezone('UTC', now()), '%Y%m%dT%H%M%SZ') AS stamp
    FROM host_processes WHERE kill_id IS NOT NULL
    GROUP BY stamp
), dumped AS (
    SELECT stamp, array_agg(selfdispatch(tera_render($d$
COPY (SELECT * FROM host_processes WHERE kill_id IS NOT NULL) TO '~/.duck/logs/reaped-{{ stamp }}.json' (FORMAT json)
$d$, json_object('stamp', stamp), autoescape := false))) AS receipts
    FROM targets GROUP BY stamp
), listed AS (
    SELECT array_agg(selfdispatch(tera_render($l$
SELECT list(DISTINCT kill_id) AS ids FROM read_json('~/.duck/logs/reaped-{{ stamp }}.json')
$l$, json_object('stamp', stamp), autoescape := false))) AS receipts
    FROM dumped CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200
), killed AS (
    SELECT array_agg(selfdispatch(tera_render($k$
SELECT content FROM read_lines($c$kill -TERM -- {{ ids | join(sep=" ") }} 2>&1; sleep 5; kill -KILL -- {{ ids | join(sep=" ") }} 2>/dev/null; echo reaped |$c$)
$k$, (r.body::JSON)[0], autoescape := false))) AS receipts
    FROM listed CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200
)
SELECT 'dump' AS step, r.status, r.body FROM dumped CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL SELECT 'list' AS step, r.status, r.body FROM listed CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL SELECT 'kill' AS step, r.status, r.body FROM killed CROSS JOIN UNNEST(receipts) AS t(r);
$reap$ AS sql
), posted AS (
    SELECT sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY sql
)
SELECT cron(sql, '0 */5 * * * *') AS job, r.status FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

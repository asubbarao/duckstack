-- Dev only (agents' clients do not read this file). Every 5 minutes, and once at boot: write every host_processes row
-- with a kill_id (processes.sql), every column, to ~/.duck/logs/reaped-<UTC time>.json, read the kill_ids back
-- from that file, and kill them (-pgid, which kill reads as the whole group, or a pid alone) in one shell line: TERM,
-- five seconds, KILL. Each step is its own post built from the previous receipt, so what is killed is what was dumped.
-- Nothing to kill, no file and no command.
WITH program AS (
    SELECT $reap$
WITH targets AS (   -- this run's stamp, only when something is marked
    SELECT DISTINCT strftime(timezone('UTC', now()), '%Y%m%dT%H%M%SZ') AS stamp FROM host_processes WHERE kill_id IS NOT NULL
), dumped AS (
    SELECT stamp, array_agg(selfdispatch(tera_render($d$
COPY (SELECT * FROM host_processes WHERE kill_id IS NOT NULL) TO '~/.duck/logs/reaped-{{ stamp }}.json' (FORMAT json)
$d$, targets::JSON, autoescape := false))) AS receipts
    FROM targets GROUP BY stamp
), listed AS (
    SELECT array_agg(selfdispatch(tera_render($l$
SELECT string_agg(DISTINCT kill_id::VARCHAR, ' ') AS ids FROM read_json('~/.duck/logs/reaped-{{ stamp }}.json')
$l$, dumped::JSON, autoescape := false))) AS receipts
    FROM dumped CROSS JOIN UNNEST(receipts) AS dump_step(receipt) WHERE dump_step.receipt.status = 200
), killed AS (
    SELECT array_agg(selfdispatch(tera_render($k$
SELECT content FROM read_lines($c$kill -TERM -- {{ ids }} 2>&1; sleep 5; kill -KILL -- {{ ids }} 2>/dev/null; echo reaped |$c$)
$k$, ids_row, autoescape := false))) AS receipts
    FROM listed CROSS JOIN UNNEST(receipts) AS list_step(receipt) CROSS JOIN UNNEST(list_step.receipt.body::JSON[]) AS listing(ids_row)
    WHERE list_step.receipt.status = 200
)
SELECT 'dump' AS step, dump_step.receipt.status, dump_step.receipt.body FROM dumped CROSS JOIN UNNEST(receipts) AS dump_step(receipt)
UNION ALL SELECT 'list' AS step, list_step.receipt.status, list_step.receipt.body FROM listed CROSS JOIN UNNEST(receipts) AS list_step(receipt)
UNION ALL SELECT 'kill' AS step, kill_step.receipt.status, kill_step.receipt.body FROM killed CROSS JOIN UNNEST(receipts) AS kill_step(receipt);
$reap$ AS sql
), posted AS (
    SELECT sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY sql
)
SELECT cron(sql, '0 */5 * * * *') AS job, boot.receipt.status FROM posted CROSS JOIN UNNEST(receipts) AS boot(receipt);

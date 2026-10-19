-- Dev only (agents' clients do not read this file). Every 5 minutes, and once at boot: kill every host_processes
-- kill_id (-pgid, which kill reads as the whole group, or a pid alone) in one shell line: TERM, five seconds, KILL.
-- Just before, it writes those pids' rows, every column, to ~/.duck/logs/reaped/<UTC time>.json: a second read of the
-- same pids, so one that exited in between is missing from the file. Nothing to kill, no file and no command.
WITH program AS (
    SELECT $reap$
WITH targets AS (
    SELECT strftime(timezone('UTC', now()), '%Y%m%dT%H%M%SZ') AS stamp, list(pid) AS pids, list(DISTINCT kill_id) AS ids
    FROM host_processes WHERE kill_id IS NOT NULL
    GROUP BY stamp
), rendered AS (
    SELECT tera_render($t$
SELECT content FROM read_lines('mkdir -p ~/.duck/logs/reaped |');
COPY (SELECT * FROM host_processes WHERE pid IN ({{ pids | join(sep=", ") }})) TO '~/.duck/logs/reaped/{{ stamp }}.json' (FORMAT json);
SELECT content FROM read_lines($k$kill -TERM -- {{ ids | join(sep=" ") }} 2>&1; sleep 5; kill -KILL -- {{ ids | join(sep=" ") }} 2>/dev/null; echo reaped |$k$);
$t$, targets::JSON, autoescape := false) AS sql
    FROM targets
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.status FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);
$reap$ AS sql
), posted AS (
    SELECT sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY sql
)
SELECT cron(sql, '0 */5 * * * *') AS job, r.status FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

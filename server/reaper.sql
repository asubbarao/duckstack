-- Dev only (agents' clients do not read this file). Every 5 minutes, and once at boot: kill every process group
-- host_processes marks reap and every process it marks reap_dev_job (alone: dev's own jobs share dev's group), in one
-- shell line: TERM, five seconds, KILL. A group is its negative pgid, which kill reads as the whole group. First the
-- marked rows, every column, go to ~/.duck/logs/reaped/<UTC time>.json. Nothing marked, no file and no command.
WITH program AS (
    SELECT $reap$
WITH targets AS (
    SELECT getenv('HOME') AS home, strftime(timezone('UTC', now()), '%Y%m%dT%H%M%SZ') AS stamp,
           list(pid) AS pids, list(DISTINCT CASE WHEN reap THEN -pgid ELSE pid END) AS ids
    FROM host_processes WHERE true IN (reap, reap_dev_job)
    GROUP BY home, stamp
), rendered AS (
    SELECT tera_render($t$
SELECT content FROM read_lines('mkdir -p {{ home }}/.duck/logs/reaped |');
COPY (SELECT * FROM host_processes WHERE pid IN ({{ pids | join(sep=", ") }})) TO '{{ home }}/.duck/logs/reaped/{{ stamp }}.json' (FORMAT json);
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

-- Dev only (agents' clients do not read this file). Every 5 minutes, and once at boot: kill every process group
-- host_processes marks reap and every process it marks reap_dev_job (alone: dev's own jobs share dev's group), in one
-- shell line: TERM, five seconds, KILL. First the marked rows, every column, go to ~/.duck/logs/reaped/<UTC time>.json,
-- the same rows the kill names. Nothing marked, no file and no command.
WITH program AS (
    SELECT $reap$
WITH marked AS (
    SELECT * FROM host_processes WHERE greatest(reap, reap_dev_job)
), targets AS (
    SELECT list_filter(list(DISTINCT CASE WHEN reap THEN '-' || pgid END) || list(CASE WHEN reap_dev_job THEN pid::VARCHAR END),
                       lambda id: id IS NOT NULL) AS ids,
           to_json(list(marked))::VARCHAR AS rows, getenv('HOME') AS home, strftime(timezone('UTC', now()), '%Y%m%dT%H%M%SZ') AS stamp
    FROM marked HAVING count(pid) > 0
), rendered AS (
    SELECT tera_render($t$
SELECT content FROM read_lines('mkdir -p {{ home }}/.duck/logs/reaped |');
COPY (SELECT unnest(($j${{ rows }}$j$::JSON)::JSON[]) AS process) TO '{{ home }}/.duck/logs/reaped/{{ stamp }}.json' (FORMAT json);
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

-- Dev only (agents' clients do not read this file). Every 5 minutes, and once at boot: append host_processes and
-- host_memory as Parquet under ~/.duck/logs/{processes,memory}/day=…/, then kill every process group host_processes
-- marks reap: one shell line, TERM, five seconds, KILL. No groups to reap, no command.
CREATE OR REPLACE VIEW host_process_history AS
FROM read_parquet('~/.duck/logs/processes/*/*.parquet', hive_partitioning := true, union_by_name := true);

CREATE OR REPLACE VIEW host_memory_history AS
FROM read_parquet('~/.duck/logs/memory/*/*.parquet', hive_partitioning := true, union_by_name := true);

WITH program AS (
    SELECT $reap$
COPY (SELECT *, strftime(observed_at, '%Y-%m-%d') AS day FROM host_processes)
TO '~/.duck/logs/processes' (FORMAT parquet, PARTITION_BY (day), APPEND, FILENAME_PATTERN 'snap_{uuid}');
COPY (SELECT *, strftime(observed_at, '%Y-%m-%d') AS day FROM host_memory)
TO '~/.duck/logs/memory' (FORMAT parquet, PARTITION_BY (day), APPEND, FILENAME_PATTERN 'snap_{uuid}');
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

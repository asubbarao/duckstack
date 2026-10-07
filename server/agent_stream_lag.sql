-- Source freshness and recent files missing entirely; run on dev (9495).
WITH disk AS (
    -- stat: birth/mtime seconds and absolute path; recurse through both native subagent trees.
    SELECT CASE WHEN starts_with(path, '/Users/aloksubbarao/.claude/') THEN 'claude' ELSE 'codex' END AS source,
        path, to_timestamp(mtime) AS file_mtime, to_timestamp(birthtime) AS file_created_at
    FROM read_csv($cmd$find /Users/aloksubbarao/.claude/projects /Users/aloksubbarao/.codex/sessions -name '*.jsonl' -type f -exec stat -f '%B,%m,%N' {} + |$cmd$,
        header := false, columns := {'birthtime':'DOUBLE', 'mtime':'DOUBLE', 'path':'VARCHAR'})
), present AS (
    SELECT source, file_path AS path, max(ts) AS newest_ts
    FROM agent.stream GROUP BY ALL
), coverage AS (
    SELECT d.*, p.newest_ts, p.path IS NULL AS missing
    FROM disk AS d LEFT JOIN present AS p USING (source, path)
), summary AS (
    SELECT source, max(file_mtime) AS newest_file_mtime, max(newest_ts) AS stream_max_ts,
        greatest(0, epoch(max(file_mtime) - max(newest_ts))) AS lag_seconds,
        list(path ORDER BY file_mtime DESC) FILTER (
            WHERE missing AND file_mtime >= now() - INTERVAL '1 day') AS recent_missing_files,
        list(path ORDER BY file_mtime DESC) FILTER (
            WHERE missing AND file_mtime >= now() - INTERVAL '1 day' AND file_created_at <= now() - INTERVAL '5 minutes') AS overdue_missing_files
    FROM coverage GROUP BY source
)
SELECT now() AS measured_at, *, stream_max_ts IS NOT NULL AND lag_seconds <= 300 AND coalesce(len(overdue_missing_files), 0) = 0 AS within_five_minutes
FROM summary ORDER BY source;

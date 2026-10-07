-- Validator for agent.stream labels: one row per (system, message_type, message_role, event_kind) with its
-- size, and `agrees` saying whether event_kind matches what the normalized role implies. Nothing is fixed
-- here; a row with agrees = false is a lead to inspect, and the fix goes in agent_stream_incremental.sql.
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
), expected AS (
    -- The event_kind each normalized message_role implies. Roles outside this list ('other') carry their
    -- own kinds (token_count, session_state, ...) and are shown without a verdict.
    SELECT 'tool_call' AS message_role, 'call_request' AS expected_kind
    UNION ALL SELECT 'tool_result', 'call_result'
    UNION ALL SELECT 'user', 'user_text'
    UNION ALL SELECT 'agent', 'agent_text'
    UNION ALL SELECT 'system', 'system_text'
), profile AS (
    SELECT system, message_type, message_role, event_kind,
        len(array_agg(id)) AS n, sum(content_length) AS chars,
        len(array_agg(id) FILTER (WHERE message_content IS NULL)) AS empty
    FROM agent.stream
    GROUP BY ALL
)
SELECT 'source_freshness' AS check_name, source AS system, source, newest_file_mtime,
    stream_max_ts, lag_seconds, recent_missing_files, overdue_missing_files,
    stream_max_ts IS NOT NULL AND lag_seconds <= 300 AND coalesce(len(overdue_missing_files), 0) = 0 AS agrees
FROM summary
UNION ALL BY NAME
SELECT 'labels' AS check_name, p.*, e.expected_kind, p.event_kind = e.expected_kind AS agrees
FROM profile AS p
LEFT JOIN expected AS e USING (message_role)
ORDER BY check_name DESC, agrees NULLS LAST, n DESC
LIMIT 100;

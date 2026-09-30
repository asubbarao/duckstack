-- Regression: Apple fractional timestamps with a spaced numeric offset must join the exit.
SELECT CASE WHEN captured_at = TIMESTAMPTZ '2026-09-28 19:55:42.6216+00'
                 AND exit_status = 139 AND crash_file IS NOT NULL
            THEN 'shutdown crash linked' ELSE error('exit lost its native crash report') END AS result
FROM meta.server_incidents WHERE pid = 23543;

SELECT CASE WHEN len(list(query_id)) = 1
            THEN 'last interrupted SQL retained' ELSE error('missing or duplicate crash-tail query') END AS result
FROM meta.server_query_log
WHERE timestamp = TIMESTAMPTZ '2026-09-28 19:55:38.77248+00'
  AND connection_id = 2093 AND query_id = 7629
  AND contains(message, 'CREATE OR REPLACE TABLE agent.stream');

SELECT CASE WHEN len(list(pid)) = 1 THEN 'one matched incident'
            ELSE error('missing or duplicate incident') END AS result
FROM meta.server_incidents WHERE pid = 23543;

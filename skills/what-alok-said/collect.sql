-- Everything Alok typed to an agent in the window, one row per session: his prompts in order, nothing else.
-- Self-dispatch: agent.entries picks the session files changed in the window, and each file is read by its own
-- narrow statement that returns only his typed text. One scan of agent.lines over every file filled dev's 15 GB.
-- Run on dev; change the window in both places (the file pick and the line filter).
WITH session_files AS (
    SELECT session, path, CASE WHEN contains(path, '/.codex/') THEN 'codex' ELSE 'claude' END AS source,
           CASE WHEN contains(path, '/.codex/') THEN 'payload' ELSE 'message' END AS message_column
    FROM agent.entries WHERE ext = '.parquet' AND modified > now() - INTERVAL 14 DAY
), dispatched AS (
    SELECT session, source, array_agg(selfdispatch(concat($q$
        SELECT (timestamp ->> '$')::TIMESTAMPTZ AS ts, coalesce(block ->> 'text', block ->> '$') AS text
        FROM (SELECT timestamp, unnest(CASE json_type(m -> 'content') WHEN 'ARRAY' THEN json_extract(m, '$.content[*]') ELSE [m -> 'content'] END) AS block
              FROM (SELECT *, $q$, message_column, $q$ AS m FROM read_parquet($q$, quote_literal(path), $q$))
              WHERE NOT contains(transcript, '/subagents/') AND (m ->> 'role') = 'user'
                AND (timestamp ->> '$')::TIMESTAMPTZ > now() - INTERVAL 14 DAY)
        WHERE coalesce(block ->> 'type', 'text') IN ('text', 'input_text')$q$))) AS receipts
    FROM session_files GROUP BY ALL
), not_typed AS (            -- text that arrives as his turn but that he did not type
    SELECT unnest(['<', '# AGENTS.md', 'This session is being continued', 'Another Claude session',
                   'Base directory for this skill', 'Here is a note offered by a side agent', '[Request interrupted']) AS prefix
), typed AS (
    SELECT session, source, receipt.status, (row ->> 'ts')::TIMESTAMPTZ AS ts, row ->> 'text' AS text
    FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt) CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS r(row)
    ANTI JOIN not_typed AS n ON starts_with(ltrim(row ->> 'text'), n.prefix)
)
SELECT source, parse_filename(session) AS session, min(ts) AS first_ts, max(ts) AS last_ts,
       len(array_agg(text)) AS prompts, sum(strlen(text)) AS chars,
       array_agg({'ts': ts, 'text': text} ORDER BY ts) AS said
FROM typed GROUP BY ALL ORDER BY first_ts;

-- Each dispatch binds the complete saved query as a literal PRAGMA argument.
-- stream_semantic loads quackformers when that host-only job actually runs; CI does not schedule it.
WITH programs AS (
    SELECT filename,
        CASE WHEN ends_with(filename, 'search.sql') THEN 'stream_search' ELSE 'stream_semantic' END AS name,
        CASE WHEN ends_with(filename, 'search.sql')
            THEN 'BM25 search over agent.stream_hour (one row per session-hour): five hours with up to five matching condensed items (id + speaker-prefixed head/tail, at most 205 chars). Never full text; use stream_message with an id for that.'
            ELSE 'Vector (cosine) search over agent.stream_hour embeddings of the human/agent exchange: five session-hours with up to five dialog items (id + head/tail). Use stream_message with an id for full text.' END AS description,
        rtrim(replace(content, '''launchctl plist wrapper server exits log''', '$q::VARCHAR'), chr(10) || chr(13) || ' ;') AS query
    FROM read_text([
        getvariable('server_dir') || '/server/agent_stream_search.sql',
        getvariable('server_dir') || '/server/agent_stream_semantic.sql'
    ])
), statements AS (
    SELECT name, printf($publish$PRAGMA mcp_publish_tool('%s', '%s', $query$%s$query$,
        '{"q":{"type":"string","description":"search words or a question"}}', '["q"]', 'markdown');$publish$,
        name, description, query) AS sql
    FROM programs
), sent AS (
    SELECT array_agg({name: name, sql: sql,
        receipt: http_post('http://localhost:' || getvariable('quackapi_port') || '/sql', MAP{'Content-Type': 'application/json'}, {'sql': sql}::JSON)}) AS receipts
    FROM statements
)
SELECT r.name, r.receipt.status AS status, r.receipt.body AS body
FROM sent CROSS JOIN UNNEST(receipts) t(r);

PRAGMA mcp_publish_tool('stream_session',
    'Compact UTC day rows for one session, with up to ten message head/tail previews per day. Use stream_message with an id for full text.',
    'SELECT * FROM agent.stream_day WHERE session_id = $session_id ORDER BY day LIMIT 100',
    '{"session_id":{"type":"string"}}', '["session_id"]', 'markdown');
PRAGMA mcp_publish_tool('stream_recent',
    'The 10 most recent compact stream rows. Text up to 200 characters is in content_head; longer text has 100-character head/tail previews. Use stream_message with an id for full text.',
    $query$WITH full_text AS (
        SELECT id, system, session_id, ts, day, message_role, status, tool_data,
            message_content, content_length, content_headtail
        FROM agent.stream WHERE ts >= current_timestamp - to_hours($hours::INTEGER)
    ), bounded AS (
        SELECT * EXCLUDE (message_content, content_headtail, tool_data), tool_data.name AS tool_name,
            CASE WHEN content_length <= 200 THEN message_content ELSE left(message_content, 100) END AS content_head,
            CASE WHEN content_length > 200 THEN right(message_content, 100) END AS content_tail
        FROM full_text
    )
    SELECT * FROM bounded ORDER BY ts DESC NULLS LAST, id DESC LIMIT 10$query$,
    '{"hours":{"type":"integer","description":"look back this many hours"}}', '["hours"]', 'markdown');
PRAGMA mcp_publish_tool('stream_message',
    'Explicitly fetch the complete text of one stream row by its id.',
    'SELECT id, system, session_id, ts, message_role, tool_data, message_content, content_length FROM agent.stream WHERE id = $id LIMIT 3',
    '{"id":{"type":"string","description":"exact agent.stream id from a compact result"}}', '["id"]', 'markdown');
PRAGMA mcp_publish_tool('stream_tools',
    'Collapse a session''s recent tool calls and outputs by hour, tool and command program. Full rows remain in agent.stream.',
    $query$WITH calls AS (
        SELECT system, session_id, ts, id, tool_use_id, status, tool_data
        FROM agent.stream
        WHERE session_id = $session_id AND message_role = 'tool_call'
          AND ts >= now() - to_hours($hours::INTEGER)
    ), results AS (
        SELECT system, session_id, ts, id, tool_use_id, status, message_content
        FROM agent.stream
        WHERE session_id = $session_id AND message_role = 'tool_result'
          AND ts >= now() - to_hours($hours::INTEGER)
    ), paired AS (
        SELECT c.id AS call_row, r.id AS result_row,
            c.tool_data.name AS tool_name,
            CASE WHEN c.tool_data.name = 'command' AND json_valid(c.tool_data.input)
                THEN split_part(json_extract_string(c.tool_data.input, '$[2]'), ' ', 1)
                ELSE NULL END AS program,
            c.tool_data.input AS input, r.message_content AS output,
            c.status AS call_status, r.status AS result_status,
            time_bucket(INTERVAL '1 hour', coalesce(c.ts, r.ts)) AS hour,
            greatest(c.ts, r.ts) AS ts
        FROM calls c FULL OUTER JOIN results r
          ON c.system = r.system AND c.session_id = r.session_id
         AND c.tool_use_id = r.tool_use_id AND c.tool_use_id IS NOT NULL
    ), grouped AS (
    SELECT hour, tool_name, program, count(DISTINCT call_row) AS calls,
        count(DISTINCT result_row) AS results,
        count(DISTINCT call_row) FILTER (WHERE call_status IN ('failed', 'error')) AS failed_calls,
        count(DISTINCT result_row) FILTER (WHERE result_status IN ('failed', 'error')) AS failed_results,
        min(ts) AS first_ts, max(ts) AS last_ts,
        list(DISTINCT left(input, 80)) FILTER (WHERE input IS NOT NULL) AS inputs,
        list(DISTINCT left(output, 80)) FILTER (WHERE output IS NOT NULL) AS outputs
    FROM paired
    GROUP BY hour, tool_name, program
    )
    SELECT * REPLACE (inputs[:3] AS inputs, outputs[:2] AS outputs)
    FROM grouped
    ORDER BY hour DESC, calls DESC, last_ts DESC LIMIT 30$query$,
    '{"session_id":{"type":"string"},"hours":{"type":"integer"}}',
    '["session_id","hours"]', 'markdown');
PRAGMA mcp_publish_tool('user_messages',
    'The 30 most recent compact user-role rows. Text up to 200 characters is in content_head; longer text has 100-character head/tail previews. Use stream_message with an id for full text.',
    $query$WITH full_text AS (
        SELECT id, system, session_id, ts, day, message_role, status, tool_data,
            message_content, content_length, content_headtail
        FROM agent.stream
        WHERE message_role = 'user' AND ts >= now() - to_hours($hours::INTEGER)
    ), bounded AS (
        SELECT * EXCLUDE (message_content, content_headtail, tool_data), tool_data.name AS tool_name,
            CASE WHEN content_length <= 200 THEN message_content ELSE left(message_content, 100) END AS content_head,
            CASE WHEN content_length > 200 THEN right(message_content, 100) END AS content_tail
        FROM full_text
    )
    SELECT * FROM bounded ORDER BY ts DESC NULLS LAST, id DESC LIMIT 30$query$,
    '{"hours":{"type":"integer","description":"how far back"}}', '["hours"]', 'markdown');

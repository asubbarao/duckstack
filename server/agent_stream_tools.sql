-- Each dispatch binds the complete saved query as a literal PRAGMA argument.
WITH programs AS (
    SELECT filename,
        CASE WHEN ends_with(filename, 'search.sql') THEN 'stream_search' ELSE 'stream_semantic' END AS name,
        CASE WHEN ends_with(filename, 'search.sql')
            THEN 'BM25 over messages and tools: ten session-days with bounded user/agent previews. Drill into agent.stream by id.'
            ELSE 'Local vector search. Embeddings fill in bounded batches; BM25 covers all non-null message text.' END AS description,
        rtrim(replace(content, '''launchctl plist wrapper server exits log''', '$q::VARCHAR'), chr(10) || chr(13) || ' ;') AS query
    FROM read_text([
        '/Users/aloksubbarao/duckdb-skills/server/agent_stream_search.sql',
        '/Users/aloksubbarao/duckdb-skills/server/agent_stream_semantic.sql'
    ])
), statements AS (
    SELECT name, printf($publish$PRAGMA mcp_publish_tool('%s', '%s', $query$%s$query$,
        '{"q":{"type":"string","description":"search words or a question"}}', '["q"]', 'markdown');$publish$,
        name, description, query) AS sql
    FROM programs
), sent AS (
    SELECT array_agg({name: name, sql: sql,
        receipt: http_post_form('http://localhost:9495/sql', MAP{}, MAP{'sql': sql})}) AS receipts
    FROM statements
)
SELECT r.name, r.receipt.status AS status, r.receipt.body AS body
FROM sent CROSS JOIN UNNEST(receipts) t(r);

PRAGMA mcp_publish_tool('stream_session',
    'Conversation previews by UTC session-day, including other records. Full original records are available in agent.conversations, keyed by source/session/file/line.',
    'SELECT * FROM agent.stream_day WHERE session_id = $session_id ORDER BY day LIMIT 100',
    '{"session_id":{"type":"string"}}', '["session_id"]', 'markdown');
PRAGMA mcp_publish_tool('stream_recent',
    'Recent sessions with ten ordered short user/agent messages each. Tool calls and outputs are available separately in agent.stream.',
    'SELECT system, session_id, project_path, days, last_ts, message_count,
        list_transform(preview, m -> [m.role, left(m.text, 100), m.ts::VARCHAR]) AS preview
     FROM agent.stream_conversation
     WHERE last_ts >= current_timestamp - to_hours($hours::INTEGER)
     ORDER BY last_ts DESC LIMIT 10',
    '{"hours":{"type":"integer","description":"look back this many hours"}}', '["hours"]', 'markdown');
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
    'User-role message samples from the last N hours, grouped by UTC session-day. At most thirty 100-character samples per group.',
    'SELECT day, system, session_id, count(id) AS message_count,
        list(left(message_content, 100) ORDER BY ts)[1:30] AS samples
     FROM agent.stream WHERE message_role = ''user'' AND ts >= now() - to_hours($hours::INTEGER)
     GROUP BY ALL ORDER BY day DESC LIMIT 100',
    '{"hours":{"type":"integer","description":"how far back"}}', '["hours"]', 'markdown');

-- Refresh every five minutes. Full originals remain in the reader-backed view.
CREATE SCHEMA IF NOT EXISTS agent;

CREATE OR REPLACE TABLE agent.stream AS
WITH source_rows AS (
    SELECT *, coalesce(nullif(message_role, ''), message_type) AS transport,
        CASE WHEN message_type IN ('function_call_output', 'custom_tool_call_output', 'tool_result') THEN false
             WHEN message_type IN ('function_call', 'custom_tool_call', 'tool_call') THEN true
             WHEN nullif(tool_input, '') IS NOT NULL THEN true
             WHEN transport = 'tool' THEN false
             WHEN nullif(tool_name, '') IS NOT NULL THEN true
             ELSE false END AS is_call,
        sha256(to_json({system: system, session_id: session_id, file_name: file_name,
            project_path: project_path, line_number: line_number, uuid: uuid,
            message_type: message_type, tool_use_id: tool_use_id})) AS source_key,
        row_number() OVER (PARTITION BY source_key
            ORDER BY timestamp, sha256(message_content), tool_name, sha256(tool_input)) AS occurrence
    FROM agent.conversations
), parts AS (
    SELECT *, 'text' AS part, nullif(message_content, '') AS content, NULL AS tool_data
    FROM source_rows
    WHERE CASE WHEN NOT is_call THEN true
        WHEN transport IN ('user', 'assistant') THEN nullif(message_content, '') IS NOT NULL
        WHEN transport = 'tool' AND message_type NOT IN ('function_call', 'custom_tool_call', 'tool_call')
            THEN nullif(message_content, '') IS NOT NULL ELSE false END
    UNION ALL BY NAME
    SELECT *, 'tool' AS part,
        nullif(concat_ws(' ', nullif(tool_name, ''), coalesce(nullif(tool_input, ''),
            CASE WHEN transport IN ('user', 'assistant') THEN NULL ELSE nullif(message_content, '') END)), '') AS content,
        {name: tool_name, input: tool_input, call_id: tool_use_id} AS tool_data
    FROM source_rows WHERE is_call
), normalized AS (
    SELECT COLUMNS(c -> c NOT IN ('tool_name', 'tool_input', 'raw_event', 'metadata',
        'source_key', 'occurrence', 'part', 'is_call', 'transport', 'content', 'message_role', 'message_content',
        'input_tokens', 'output_tokens', 'cache_creation_tokens', 'cache_read_tokens', 'reasoning_tokens')),
        message_role AS source_message_role, source_key || ':' || occurrence || ':' || part AS id,
        CASE WHEN part = 'tool' THEN 'tool_call'
             WHEN message_type IN ('function_call_output', 'custom_tool_call_output', 'tool_result') THEN 'tool_result'
             WHEN transport = 'tool' THEN 'tool_result'
             WHEN transport = 'user' THEN 'user'
             WHEN transport IN ('assistant', 'reasoning', 'agent_message') THEN 'agent'
             WHEN transport IN ('system', 'developer') THEN 'system' ELSE 'other' END AS message_role,
        content AS message_content, length(content) AS content_length,
        try_cast(timestamp AS TIMESTAMPTZ) AS ts,
        (ts AT TIME ZONE 'UTC')::DATE AS day, time_bucket(INTERVAL '5 minutes', ts) AS block
    FROM parts
)
SELECT *, CASE WHEN content_length > 2000
    THEN left(message_content, 1000) || ' … ' || right(message_content, 997)
    ELSE message_content END AS content_headtail
FROM normalized;

CREATE OR REPLACE VIEW agent.stream_day AS
WITH days AS (
    SELECT system, session_id, day, count(id) AS message_count, min(ts) AS first_ts, max(ts) AS last_ts,
        list(DISTINCT coalesce(nullif(cwd, ''), nullif(project_path, ''))) AS directories,
        list({id: id, uuid: uuid, role: message_role,
              content_head: CASE WHEN content_length <= 200 THEN message_content ELSE left(message_content, 100) END,
              content_tail: CASE WHEN content_length > 200 THEN right(message_content, 100) END,
              content_length: content_length, ts: ts}
            ORDER BY ts DESC NULLS LAST, file_name, line_number, id) AS messages
    FROM agent.stream GROUP BY ALL
)
SELECT * EXCLUDE (messages), messages[:10] AS samples
FROM days;

-- A compact entry point; full messages and tool activity remain in agent.stream.
CREATE OR REPLACE VIEW agent.stream_conversation AS
WITH messages AS (
    SELECT system, session_id, project_path, day, block, ts, id, uuid,
        message_role, message_content, content_length,
        row_number() OVER (PARTITION BY system, session_id
            ORDER BY ts DESC NULLS LAST, id DESC) AS recent_rank
    FROM agent.stream
    WHERE message_role IN ('user', 'agent') AND message_content IS NOT NULL
), sessions AS (
    SELECT system, session_id, arg_max(project_path, ts) AS project_path,
        list(DISTINCT day ORDER BY day) AS days,
        min(ts) AS first_ts, max(ts) AS last_ts, count(id) AS message_count,
        list({id: id, uuid: uuid, role: message_role,
              content_head: CASE WHEN content_length <= 200 THEN message_content ELSE left(message_content, 100) END,
              content_tail: CASE WHEN content_length > 200 THEN right(message_content, 100) END,
              content_length: content_length, ts: ts} ORDER BY ts, id)
            FILTER (WHERE recent_rank <= 10) AS preview
    FROM messages
    GROUP BY system, session_id
)
SELECT * FROM sessions;

-- Canonical native-event normalization, shared by bounded cold and incremental reads.
CREATE OR REPLACE TEMP TABLE stream_changed_delta AS
WITH call_type(message_type, event_kind, call_role) AS (
    SELECT 'function_call_output', 'call_result', 'tool_result' UNION ALL SELECT 'custom_tool_call_output', 'call_result', 'tool_result' UNION ALL SELECT 'tool_result', 'call_result', 'tool_result'
    UNION ALL SELECT 'function_call', 'call_request', NULL UNION ALL SELECT 'custom_tool_call', 'call_request', NULL UNION ALL SELECT 'tool_call', 'call_request', NULL
), record_type(message_type, event_kind) AS (
    SELECT '_parse_error', 'reader_error' UNION ALL SELECT 'token_usage', 'token_count' UNION ALL SELECT 'token_usage_total', 'token_count' UNION ALL SELECT 'token_count', 'token_count'
    UNION ALL SELECT 'attachment', 'attachment' UNION ALL SELECT 'image_view', 'attachment' UNION ALL SELECT 'file_change', 'file_edit' UNION ALL SELECT 'file-history-snapshot', 'file_edit' UNION ALL SELECT 'file-history-delta', 'file_edit'
    UNION ALL SELECT 'inter_agent_communication_metadata', 'subagent_link' UNION ALL SELECT 'subagent_activity', 'subagent_link' UNION ALL SELECT 'queue-operation', 'turn_lifecycle' UNION ALL SELECT 'task_started', 'turn_lifecycle' UNION ALL SELECT 'task_complete', 'turn_lifecycle' UNION ALL SELECT 'turn_aborted', 'turn_lifecycle' UNION ALL SELECT 'compacted', 'turn_lifecycle' UNION ALL SELECT 'compaction', 'turn_lifecycle' UNION ALL SELECT 'compaction_summary', 'turn_lifecycle' UNION ALL SELECT 'retained_context', 'turn_lifecycle' UNION ALL SELECT 'plan', 'turn_lifecycle'
    UNION ALL SELECT 'last-prompt', 'session_state' UNION ALL SELECT 'ai-title', 'session_state' UNION ALL SELECT 'custom-title', 'session_state' UNION ALL SELECT 'agent-name', 'session_state' UNION ALL SELECT 'agent-setting', 'session_state' UNION ALL SELECT 'mode', 'session_state' UNION ALL SELECT 'permission-mode', 'session_state' UNION ALL SELECT 'pr-link', 'session_state' UNION ALL SELECT 'frame-link', 'session_state' UNION ALL SELECT 'bridge-session', 'session_state' UNION ALL SELECT 'worktree-state', 'session_state' UNION ALL SELECT 'relocated', 'session_state' UNION ALL SELECT 'continued-in', 'session_state' UNION ALL SELECT 'history-suppression', 'session_state' UNION ALL SELECT 'cost-state', 'session_state' UNION ALL SELECT 'atis-latch', 'session_state' UNION ALL SELECT 'artifact-autoreact-ledger', 'session_state' UNION ALL SELECT 'artifact-comment-monitor', 'session_state' UNION ALL SELECT 'world_state', 'session_state' UNION ALL SELECT 'thread_settings_applied', 'session_state' UNION ALL SELECT 'extension', 'session_state'
), speaker_event(speaker, event_kind) AS (
    SELECT 'user', 'user_text' UNION ALL SELECT 'assistant', 'agent_text' UNION ALL SELECT 'reasoning', 'agent_text' UNION ALL SELECT 'agent_message', 'agent_text' UNION ALL SELECT 'system', 'system_text' UNION ALL SELECT 'developer', 'system_text'
), tool_event(tool_key, event_kind) AS (
    SELECT 'input', 'call_request' UNION ALL SELECT 'speaker', 'call_result' UNION ALL SELECT 'name', 'call_request'
), role_map(speaker, normalized_role) AS (
    SELECT 'tool', 'tool_result' UNION ALL SELECT 'user', 'user' UNION ALL SELECT 'assistant', 'agent' UNION ALL SELECT 'reasoning', 'agent' UNION ALL SELECT 'agent_message', 'agent' UNION ALL SELECT 'system', 'system' UNION ALL SELECT 'developer', 'system'
), source_base AS (
    SELECT *, CASE WHEN message_role <> '' THEN message_role ELSE message_type END AS speaker FROM stream_source
), source_rows AS (
    SELECT b.*, coalesce(c.event_kind, t.event_kind, s.event_kind, r.event_kind, 'unlabeled') AS event_kind, c.call_role,
        sha256(to_json({system: system, session_id: session_id, file_path: file_path, file_name: file_name, project_path: project_path, line_number: line_number, uuid: uuid, message_type: message_type, tool_use_id: tool_use_id})) AS source_key,
        row_number() OVER (PARTITION BY source_key ORDER BY timestamp, sha256(message_content), tool_name, sha256(tool_input)) AS occurrence
    FROM source_base AS b LEFT JOIN call_type AS c USING (message_type)
    LEFT JOIN tool_event AS t ON t.tool_key = CASE WHEN tool_input <> '' THEN 'input' WHEN speaker = 'tool' THEN 'speaker' WHEN tool_name <> '' THEN 'name' END
    LEFT JOIN speaker_event AS s USING (speaker) LEFT JOIN record_type AS r USING (message_type)
), parts AS (
    SELECT *, 'text' AS part, nullif(message_content, '') AS content, NULL AS tool_data FROM source_rows
    WHERE CASE WHEN event_kind <> 'call_request' THEN true WHEN speaker IN ('user', 'assistant') THEN message_content <> '' WHEN speaker = 'tool' AND message_type NOT IN ('function_call', 'custom_tool_call', 'tool_call') THEN message_content <> '' ELSE false END
    UNION ALL BY NAME
    SELECT *, 'tool' AS part, nullif(concat_ws(' ', nullif(tool_name, ''), CASE WHEN tool_input <> '' THEN tool_input WHEN speaker IN ('user', 'assistant') THEN NULL ELSE nullif(message_content, '') END), '') AS content, {name: tool_name, input: tool_input, call_id: tool_use_id} AS tool_data FROM source_rows WHERE event_kind = 'call_request'
), normalized AS (
    SELECT * EXCLUDE (tool_name, tool_input, session_updated_at, source_key, occurrence, part, speaker, content, message_role, message_content, call_role, normalized_role), message_role AS source_message_role, source_key || ':' || occurrence || ':' || part AS id,
        CASE WHEN part = 'tool' THEN 'tool_call' ELSE coalesce(call_role, m.normalized_role, 'other') END AS message_role,
        content AS message_content, length(content) AS content_length, try_cast(timestamp AS TIMESTAMPTZ) AS ts, (ts AT TIME ZONE 'UTC')::DATE AS day, time_bucket(INTERVAL '5 minutes', ts) AS block
    FROM parts LEFT JOIN role_map AS m USING (speaker)
)
SELECT *, CASE WHEN content_length > 2000 THEN left(message_content, 1000) || ' … ' || right(message_content, 997) ELSE message_content END AS content_headtail FROM normalized;

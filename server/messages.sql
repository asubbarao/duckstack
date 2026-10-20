-- The views over stream.blocks (blocks.sql), posted once at boot after the table exists.
-- agent.messages: stream.blocks without the full text (head, tail), so a 290 KB paste never fills a reply.
-- agent.sessions: one row per session, every column carried: activity, the session's files, models, tools, last cwd
-- and branch, its block_keys, and prompts, every typed prompt as its whole stream.blocks row in order, each with
-- is_near_repeat (within rapidfuzz_ratio 90 of the one before); prompt_count, first_prompt and last_prompt skip
-- those. Select the columns a reply needs.
-- agent.tool_calls: one row per tool call (Claude tool_use, Codex function_call / custom_tool_call) with its result
-- joined on (file_path, tool_use_id): called_at, returned_at, took, result_text, is_error.
-- agent.conversation: messages and tool calls as one relation. Message rows have tool NULL; a 'tool_call' row's
-- message_content is the command and tool holds the call and its result. block_key matches stream.blocks, so BM25
-- (fts_main_blocks.match_bm25(block_key, '...')) scores both.
WITH messages_step AS (
    SELECT array_agg(selfdispatch($m$
CREATE OR REPLACE VIEW agent.messages AS
SELECT * EXCLUDE (message_content, tool_input, tool_command), left(message_content, 100) AS head,
       right(message_content, 100) AS tail, left(tool_command, 100) AS tool_command_head
FROM stream.blocks
$m$)) AS receipts
), sessions_step AS (
    SELECT array_agg(selfdispatch($s$
CREATE OR REPLACE VIEW agent.sessions AS
WITH session_blocks AS (
    SELECT * FROM stream.blocks WHERE NOT is_repeat
), prompt AS (
    SELECT *, coalesce(rapidfuzz_ratio(left(message_content, 100),
               lag(left(message_content, 100)) OVER (PARTITION BY session_id ORDER BY timestamp)) >= 90, false) AS is_near_repeat
    FROM session_blocks WHERE is_prompt
), prompts AS (
    SELECT session_id, array_agg(prompt ORDER BY timestamp) AS prompts,
           [p FOR p IN prompts IF NOT p.is_near_repeat] AS distinct_prompts
    FROM prompt GROUP BY session_id
), activity AS (
    SELECT session_id, source, min(timestamp) AS started, max(timestamp) AS last_active,
           arg_max(cwd, timestamp) AS cwd, arg_max(git_branch, timestamp) AS git_branch, arg_max(entrypoint, timestamp) AS entrypoint,
           list(DISTINCT model) AS models, list(DISTINCT tool_name) AS tools, list(DISTINCT file_path) AS files,
           bool_or(is_agent) AS has_agents, sum(content_bytes) AS bytes,
           array_agg(block_key ORDER BY timestamp) AS block_keys, len(block_keys) AS blocks
    FROM session_blocks GROUP BY session_id, source
)
SELECT a.*, p.prompts, len(p.distinct_prompts) AS prompt_count,
       p.distinct_prompts[1].message_content AS first_prompt, p.distinct_prompts[-1].message_content AS last_prompt
FROM activity a LEFT JOIN prompts p USING (session_id)
$s$)) AS receipts
    FROM messages_step CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200
), tool_calls_step AS (
    SELECT array_agg(selfdispatch($c$
CREATE OR REPLACE VIEW agent.tool_calls AS
WITH session_blocks AS (
    SELECT * FROM stream.blocks WHERE NOT is_repeat
), calls AS (
    SELECT * FROM session_blocks WHERE block_type IN ('tool_use', 'function_call', 'custom_tool_call')
), results AS (
    SELECT file_path, tool_use_id, timestamp AS returned_at, message_content AS result_text, is_error,
           content_bytes AS result_bytes, block_key AS result_block_key
    FROM session_blocks WHERE block_type IN ('tool_result', 'function_call_output', 'custom_tool_call_output')
)
SELECT calls.source, calls.session_id, calls.is_agent, calls.file_path, calls.cwd, calls.git_branch, calls.model,
       calls.block_key, calls.tool_use_id, calls.tool_name, calls.tool_input, calls.tool_command,
       calls.timestamp AS called_at, results.returned_at, results.returned_at - calls.timestamp AS took,
       results.result_text, results.is_error, calls.content_bytes AS call_bytes, results.result_bytes, results.result_block_key
FROM calls LEFT JOIN results USING (file_path, tool_use_id)
$c$)) AS receipts
    FROM sessions_step CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200
), conversation_step AS (
    SELECT array_agg(selfdispatch($v$
CREATE OR REPLACE VIEW agent.conversation AS
SELECT source, session_id, is_agent, timestamp, block_key, block_type, message_role, message_content, NULL AS tool
FROM stream.blocks
WHERE NOT is_repeat AND block_type NOT IN ('tool_use', 'function_call', 'custom_tool_call', 'tool_result', 'function_call_output', 'custom_tool_call_output')
UNION ALL BY NAME
SELECT source, session_id, is_agent, called_at AS timestamp, block_key, 'tool_call' AS block_type, 'tool_call' AS message_role,
       tool_command AS message_content,
       {'name': tool_name, 'input': tool_input, 'result': result_text, 'is_error': is_error, 'took': took, 'result_bytes': result_bytes} AS tool
FROM agent.tool_calls
$v$)) AS receipts
    FROM tool_calls_step CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200
)
SELECT r.* FROM messages_step CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL
SELECT r.* FROM sessions_step CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL
SELECT r.* FROM tool_calls_step CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL
SELECT r.* FROM conversation_step CROSS JOIN UNNEST(receipts) AS t(r);

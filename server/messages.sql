-- The views over stream.blocks (blocks.sql), posted once at boot after the table exists.
-- agent.messages: stream.blocks without the full text (head, tail), so a 290 KB paste never fills a reply.
-- agent.sessions: one row per session, every column carried: activity, the session's files, models, tools, last cwd
-- and branch, its block_keys, and prompts, every typed prompt as its whole stream.blocks row in order, each with
-- is_near_repeat (within rapidfuzz_ratio 90 of the one before); prompt_count, first_prompt and last_prompt skip
-- those. Select the columns a reply needs.
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
)
SELECT r.* FROM messages_step CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL
SELECT r.* FROM sessions_step CROSS JOIN UNNEST(receipts) AS t(r);

-- agent.activity: one row per session and Pacific time bucket over the last `lookback`; the caller picks both.
-- FROM agent.activity(lookback := INTERVAL 30 DAY, bucket := INTERVAL 1 DAY)
CREATE OR REPLACE MACRO agent.activity(lookback := INTERVAL 7 DAY, bucket := INTERVAL 1 HOUR) AS TABLE
SELECT source, session_id, time_bucket(bucket, ts_pst) AS bucket_pst,
       arg_max(cwd, timestamp) AS cwd, arg_max(git_branch, timestamp) AS git_branch,
       count_if(is_prompt) AS prompts, count_if(message_role = 'assistant' AND block_type = 'text' AND NOT is_agent) AS replies,
       count_if(tool_part = 'call') AS tool_calls, count_if(tool_part = 'result' AND is_error) AS tool_errors,
       count_if(is_agent) AS subagent_blocks, sum(content_bytes) AS bytes
FROM stream.blocks
WHERE NOT is_repeat AND timestamp > now() - lookback
GROUP BY ALL;

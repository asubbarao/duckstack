-- One row per subagent transcript touched in the last 6 hours, read by agent_data from
-- ~/.claude/projects: which model, what it was asked, how long it has run, how busy it is, what
-- it did last, what it cost in tokens, and whether it finished, is working, or went quiet.
-- A subagent's own first user turn is its brief; its last stop_reason says whether it ended.
LOAD agent_data;
WITH line AS (
  SELECT session_id, file_name, line_number, timestamp::TIMESTAMPTZ AS ts, message_role, model,
    tool_name, tool_input, message_content, stop_reason,
    input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens
  FROM read_conversations()
  WHERE is_agent),
agent AS (
  SELECT session_id, replace(replace(file_name, 'agent-', ''), '.jsonl', '') AS agent_id,
    (array_agg(model ORDER BY line_number) FILTER (model IS NOT NULL))[1] AS model,
    (array_agg(message_content ORDER BY line_number) FILTER (message_role = 'user'))[1] AS message_content,
    (array_agg(ts ORDER BY ts))[1] AS started,
    (array_agg(ts ORDER BY ts DESC))[1] AS last_seen,
    array_agg(tool_name ORDER BY line_number) FILTER (tool_name IS NOT NULL) AS tools,
    (array_agg(tool_name || ' ' || coalesce(tool_input, '') ORDER BY line_number DESC)
      FILTER (tool_name IS NOT NULL))[1][:160] AS last_tool,
    (array_agg(stop_reason ORDER BY line_number DESC) FILTER (stop_reason IS NOT NULL))[1] AS last_stop,
    sum(input_tokens) AS input_tokens, sum(output_tokens) AS output_tokens,
    sum(cache_read_tokens) AS cache_read_tokens, sum(cache_creation_tokens) AS cache_creation_tokens
  FROM line
  GROUP BY ALL),
bounded AS (
  SELECT * EXCLUDE (message_content),
    CASE WHEN length(message_content) <= 200 THEN message_content ELSE left(message_content, 100) END AS content_head,
    CASE WHEN length(message_content) > 200 THEN right(message_content, 100) END AS content_tail,
    length(message_content) AS content_length
  FROM agent)
SELECT session_id, agent_id, model, content_head, content_tail, content_length, started, last_seen - started AS ran_for,
  now() - last_seen AS idle, len(tools) AS tool_calls, last_tool,
  input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
  CASE WHEN last_stop = 'end_turn' THEN 'finished'
       WHEN now() - last_seen > INTERVAL 5 MINUTE THEN 'quiet (stopped or stuck)'
       ELSE 'working' END AS state
FROM bounded
WHERE last_seen > now() - INTERVAL 6 HOUR
ORDER BY started DESC;

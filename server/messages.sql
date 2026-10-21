-- The views over stream.blocks (blocks.sql), posted once at boot after the table exists.
-- agent.messages: stream.blocks without the full text (head, tail), so a 290 KB paste never fills a reply.
-- agent.sessions: one row per session, every column carried: activity, the session's files, models, tools, last cwd
-- and branch, its block_keys, and prompts, every typed prompt as its whole stream.blocks row in order, each with
-- is_near_repeat (within rapidfuzz_ratio 90 of the one before); prompt_count, first_prompt and last_prompt skip
-- those. Select the columns a reply needs.
-- agent.tool_clusters: one row per run of tool calls in one transcript file with no gap over a minute, deduped by
-- tool_use_id: tools, kinds (Bash verbs or the tool name), every full command, result bytes, took. A long run of
-- small calls is a candidate for one query. Filter with WHERE (started, session_id, n_bash, kinds).
-- Each view is a row; the dispatch is a column. The views read only stream.blocks, so no row waits on another.
WITH views AS (
    SELECT v.* FROM UNNEST([
        {name: 'agent.messages', sql: $m$
CREATE OR REPLACE VIEW agent.messages AS
SELECT * EXCLUDE (message_content, tool_input, tool_command), left(message_content, 100) AS head,
       right(message_content, 100) AS tail, left(tool_command, 100) AS tool_command_head
FROM stream.blocks
$m$},
        {name: 'agent.sessions', sql: $s$
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
$s$},
        {name: 'agent.tool_clusters', sql: $c$
CREATE OR REPLACE VIEW agent.tool_clusters AS
WITH tool_calls AS (
    SELECT tool_use_id, source, session_id, file_path, is_agent, model, tool_name, tool_command, min(timestamp) AS called_at
    FROM stream.blocks WHERE block_type = 'tool_use' AND tool_use_id IS NOT NULL
    GROUP BY ALL
), tool_results AS (
    SELECT tool_use_id, max(content_bytes) AS result_bytes, max(timestamp) AS result_at
    FROM stream.blocks WHERE block_type = 'tool_result' GROUP BY ALL
), calls AS (
    SELECT c.*, r.result_bytes, r.result_at,
           CASE WHEN c.tool_name = 'Bash'
                THEN list_intersect(string_split(replace(c.tool_command, E'\n', ' '), ' '),
                     ['git','gh','uv','npx','npm','ls','podman','cat','perl','duckdb','pytest','rm','printf','echo','curl',
                      'python3','jq','find','grep','sed','awk','head','tail','mkdir','cp','mv','osascript'])
                ELSE [c.tool_name] END AS kinds,
           coalesce(c.called_at - lag(c.called_at) OVER (PARTITION BY c.file_path ORDER BY c.called_at) > INTERVAL 1 MINUTE, true)::INT AS starts_cluster
    FROM tool_calls c LEFT JOIN tool_results r USING (tool_use_id)
), clustered AS (
    SELECT *, sum(starts_cluster) OVER (PARTITION BY file_path ORDER BY called_at) AS cluster_no FROM calls
)
SELECT source, session_id, file_path, is_agent, cluster_no,
       min(called_at) AS started, max(coalesce(result_at, called_at)) AS ended, ended - started AS took,
       array_agg(tool_name ORDER BY called_at) AS tools, len(tools) AS n_calls,
       len(list_filter(tools, t -> t = 'Bash')) AS n_bash,
       list_distinct(flatten(array_agg(kinds))) AS kinds,
       array_agg(tool_command ORDER BY called_at) AS commands,
       sum(result_bytes) AS result_bytes, list_distinct(array_agg(model)) AS models
FROM clustered GROUP BY ALL
$c$}
    ]) AS t(v)
)
SELECT unnest(selfdispatch(sql)) FROM views;

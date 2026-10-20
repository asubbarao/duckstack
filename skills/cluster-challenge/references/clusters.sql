-- Episodes of tool calls with signatures and real token cost (cluster-challenge §1). One row per episode: a new
-- episode after a 2-min gap or an arm switch (DuckDB/MCP vs not). Signatures come from sitting_duck: bash `command`
-- nodes, SQL `invocation` nodes, and the shell commands inside a SQL `'… |'` literal. new_tokens counts each next
-- assistant turn once (parallel calls share one). The window is 2 days to stay under dev's 2-min deadline.
WITH uses AS (
  SELECT tool_use_id, arg_min({'file_path': file_path, 'line': line, 'ts': timestamp, 'tool_name': tool_name, 'cmd': tool_command, 'input': tool_input}, line) AS u
  FROM stream.blocks WHERE block_type = 'tool_use' AND NOT is_repeat AND timestamp > now() - INTERVAL 2 DAY AND NOT contains(file_path, '/.codex/')
  GROUP BY tool_use_id
), results AS (
  SELECT tool_use_id, arg_min({'result_line': line, 'result_bytes': content_bytes, 'is_image': contains(left(message_content, 200), '"type":"image"')}, line) AS r
  FROM stream.blocks WHERE block_type = 'tool_result' AND NOT is_repeat AND timestamp > now() - INTERVAL 2 DAY GROUP BY tool_use_id
), usage AS (
  SELECT transcript, file_row_number,
         (message -> 'usage' ->> 'cache_creation_input_tokens')::BIGINT + (message -> 'usage' ->> 'input_tokens')::BIGINT + (message -> 'usage' ->> 'output_tokens')::BIGINT AS new_tokens
  FROM agent.lines WHERE type ->> '$' = 'assistant' AND (timestamp ->> '$')::TIMESTAMPTZ > now() - INTERVAL 2 DAY AND NOT contains(transcript, '/.codex/')
), call_data AS (
  SELECT uses.tool_use_id, u.*, r.*,
         CASE WHEN starts_with(u.tool_name, 'mcp__dev__') THEN 'duckdb' WHEN starts_with(u.tool_name, 'mcp__duck__') THEN 'duckdb' ELSE 'not_duckdb' END AS arm,
         CASE WHEN u.tool_name = 'Bash' THEN [n.peek FOR n IN parse_ast_list(u.cmd, 'bash') IF n.type = 'command'] END AS bash_commands,
         CASE WHEN contains(u.tool_name, '__query') THEN parse_ast_list(u.cmd, 'sql') END AS sql_nodes,
         [n.name FOR n IN sql_nodes IF n.type = 'invocation' AND CASE WHEN starts_with(n.name, 'read_') THEN true ELSE list_contains(['selfdispatch', 'git_log', 'git_status', 'git_tree', 'git_diff_tree', 'git_read_each', 'parse_ast_list', 'match_bm25'], n.name) END] AS sql_readers,
         flatten([[c.peek FOR c IN parse_ast_list(trim(replace(replace(n.name, '$cmd$', ''), '''', ''), ' |'), 'bash') IF c.type = 'command'] FOR n IN sql_nodes IF n.type = 'literal' AND ends_with(rtrim(replace(replace(n.name, '$cmd$', ''), '''', '')), '|')]) AS inner_commands,
         [CASE WHEN string_split(c, ' ')[1] = 'git' THEN 'git ' || string_split(c, ' ')[2] ELSE parse_filename(string_split(c, ' ')[1]) END FOR c IN list_concat(coalesce(bash_commands, []), inner_commands) IF NOT list_contains(['cd', 'echo', 'export', 'source', 'true', 'sleep'], string_split(c, ' ')[1]) AND NOT contains(string_split(c, ' ')[1], '=')] AS programs,
         CASE WHEN u.tool_name = 'Read' THEN u.input ->> 'file_path' END AS read_path,
         list_sort(list_distinct(list_concat(programs, sql_readers, CASE WHEN u.tool_name IN ('Bash', 'mcp__dev__query', 'mcp__duck__query') THEN [] ELSE [u.tool_name] END))) AS call_signature
  FROM uses JOIN results USING (tool_use_id)
), with_tokens AS (
  SELECT call_data.*, usage.file_row_number AS next_turn, usage.new_tokens
  FROM call_data ASOF JOIN usage ON call_data.file_path = usage.transcript AND usage.file_row_number >= call_data.result_line + 1
), episode_starts AS (
  SELECT *, CASE WHEN lag(ts) OVER w IS NULL THEN 1 WHEN ts - lag(ts) OVER w > INTERVAL 2 MINUTE THEN 1 WHEN arm <> lag(arm) OVER w THEN 1 ELSE 0 END AS starts_episode
  FROM with_tokens WINDOW w AS (PARTITION BY file_path ORDER BY ts)
), episodes AS (
  SELECT *, sum(starts_episode) OVER (PARTITION BY file_path ORDER BY ts) AS episode FROM episode_starts
), episode_rows AS (
  SELECT file_path, episode, arm, arg_min(ts, ts) AS started, arg_max(ts, ts) AS ended,
         list_sort(list_distinct(flatten(list(call_signature)))) AS signature, len(list(ts)) AS calls,
         list_distinct(list({'turn': next_turn, 'tokens': new_tokens})) AS turns,
         list_sum([t.tokens FOR t IN turns]) AS new_tokens,
         list_filter(list(read_path), p -> p IS NOT NULL) AS read_paths, len(read_paths) - len(list_distinct(read_paths)) AS rereads
  FROM episodes GROUP BY ALL
)
SELECT arm, signature, calls, len(turns) AS turns, new_tokens, rereads, file_path, started, ended
FROM episode_rows WHERE calls >= 15 ORDER BY new_tokens DESC LIMIT 10

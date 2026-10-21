-- Episodes of tool calls with signatures and real token cost (cluster-challenge §1). One row per episode: a new
-- episode after a gap or an arm switch (DuckDB/MCP vs not). Signatures come from sitting_duck: the command_name of
-- each bash `command` (git with its subcommand), SQL `invocation` nodes, and the shell commands inside a SQL `'… |'`
-- literal. new_tokens counts each API response once, keyed on message.id: one response is written to several
-- transcript lines (one per content block) and parallel calls share one. The usage CTE is lean-results' too; it
-- moves into the proposed agent.turn_usage view (lean-results/SKILL.md). Known gap: in some subagent transcripts
-- agent.lines.file_row_number and stream.blocks.line disagree, so the ASOF join can attach a later turn.
WITH uses AS (
  SELECT file_path, tool_use_id, line, timestamp AS ts, tool_name, tool_command, tool_input,
         now() - INTERVAL 2 DAY AS since, INTERVAL 2 MINUTE AS episode_gap, 15 AS min_calls, ['mcp__dev__', 'mcp__duck__'] AS duckdb_prefixes,
         ['selfdispatch', 'git_log', 'git_status', 'git_tree', 'git_diff_tree', 'git_read_each', 'parse_ast_list', 'match_bm25'] AS sql_reader_names,
         ['cd', 'echo', 'export', 'source', 'true', 'sleep'] AS skipped_programs
  FROM stream.blocks WHERE block_type = 'tool_use' AND NOT is_repeat AND timestamp > since AND source = 'claude'
), results AS (
  SELECT file_path, tool_use_id, line AS result_line, content_bytes AS result_bytes, contains(left(message_content, 200), '"type":"image"') AS is_image
  FROM stream.blocks SEMI JOIN uses USING (file_path, tool_use_id) WHERE block_type = 'tool_result' AND NOT is_repeat
), transcripts AS (
  SELECT DISTINCT file_path AS transcript, since FROM uses
), usage AS (
  SELECT transcript, file_row_number, json_extract_string(message, '$.id') AS response_id,
         list_sum(json_extract_string(message, ['$.usage.cache_creation_input_tokens', '$.usage.input_tokens', '$.usage.output_tokens'])::BIGINT[]) AS new_tokens
  FROM agent.lines JOIN transcripts USING (transcript) WHERE new_tokens IS NOT NULL AND timestamp::TIMESTAMPTZ > since
), call_data AS (
  SELECT uses.*, results.* EXCLUDE (file_path, tool_use_id),
         CASE WHEN list_bool_or([starts_with(tool_name, p) FOR p IN duckdb_prefixes]) THEN 'duckdb' ELSE 'not_duckdb' END AS arm,
         CASE WHEN contains(tool_name, '__query') THEN parse_ast_list(tool_command, 'sql') END AS sql_nodes,
         [n.name FOR n IN sql_nodes IF n.type = 'invocation' AND list_bool_or([starts_with(n.name, 'read_'), list_contains(sql_reader_names, n.name)])] AS sql_readers,
         [rtrim(translate(replace(n.name, '$cmd$', ''), $q$'$q$, '')) FOR n IN sql_nodes IF n.type = 'literal'] AS literal_texts,
         list_concat(CASE WHEN tool_name = 'Bash' THEN [tool_command] END, [trim(l, ' |') FOR l IN literal_texts IF ends_with(l, '|')]) AS shell_texts,
         CASE WHEN tool_name = 'Read' THEN tool_input ->> 'file_path' END AS read_path
  FROM uses JOIN results USING (file_path, tool_use_id)
), shell_nodes AS (
  SELECT file_path, tool_use_id, skipped_programs, text_no, n.type, n.parent_id, n.sibling_index, n.peek
  FROM call_data CROSS JOIN UNNEST(shell_texts) WITH ORDINALITY AS s(shell_text, text_no)
  CROSS JOIN UNNEST(parse_ast_list(shell_text, 'bash')) AS t(n)
), programs AS (
  SELECT name.file_path, name.tool_use_id, list(DISTINCT CASE WHEN name.peek = 'git' THEN concat_ws(' ', name.peek, arg.peek) ELSE parse_filename(name.peek) END) AS programs
  FROM shell_nodes AS name LEFT JOIN shell_nodes AS arg
    ON (arg.file_path, arg.tool_use_id, arg.text_no, arg.parent_id, arg.sibling_index) = (name.file_path, name.tool_use_id, name.text_no, name.parent_id, name.sibling_index + 1)
  WHERE name.type = 'command_name' AND NOT list_contains(name.skipped_programs, name.peek)
  GROUP BY ALL
), with_tokens AS (
  SELECT call_data.*, usage.response_id AS next_turn, usage.new_tokens,
         list_sort(list_distinct(list_concat(programs.programs, sql_readers, CASE WHEN tool_name IN ('Bash', 'mcp__dev__query', 'mcp__duck__query') THEN [] ELSE [tool_name] END))) AS call_signature
  FROM call_data LEFT JOIN programs USING (file_path, tool_use_id)
  ASOF JOIN usage ON call_data.file_path = usage.transcript AND usage.file_row_number > call_data.result_line
), episode_starts AS (
  SELECT *, list_bool_or([arm IS DISTINCT FROM lag(arm) OVER w, ts - lag(ts) OVER w > episode_gap])::INT AS starts_episode
  FROM with_tokens WINDOW w AS (PARTITION BY file_path ORDER BY ts)
), episodes AS (
  SELECT *, sum(starts_episode) OVER (PARTITION BY file_path ORDER BY ts) AS episode FROM episode_starts
), episode_rows AS (
  SELECT file_path, episode, arm, min_calls, min(ts) AS started, max(ts) AS ended,
         list_sort(list_distinct(flatten(list(call_signature)))) AS signature, len(list(ts)) AS calls,
         list_distinct(list({'turn': next_turn, 'tokens': new_tokens})) AS turns,
         list_sum([t.tokens FOR t IN turns]) AS new_tokens,
         list_filter(list(read_path), p -> p IS NOT NULL) AS read_paths, len(read_paths) - len(list_distinct(read_paths)) AS rereads
  FROM episodes GROUP BY ALL
)
SELECT arm, signature, calls, len(turns) AS turns, new_tokens, rereads, file_path, started, ended
FROM episode_rows WHERE calls >= min_calls ORDER BY new_tokens DESC LIMIT 10

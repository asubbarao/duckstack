-- One row per Luna (Codex worker) any Claude or Codex agent launched, joined to the agent that
-- launched it. Launchers write one folder per run (luna-fanout skill):
--   ~/.duck/luna_runs/parent_system=<claude|codex>/parent=<session id>/luna=<slug>/
--     brief.md  events.jsonl (codex exec --json)  run.log (stderr)  out.md  exit
-- The folder names carry the parent link, which Codex itself does not record (its
-- parent_session_id is empty for codex exec); the thread id in events.jsonl joins agent.stream.
-- A run with no exit file is still running; agent.stream shows how recently it acted.
WITH ev AS (
  -- read_json(path, format, hive_partitioning, union_by_name, filename; others default)
  FROM read_json('~/.duck/luna_runs/*/*/*/events.jsonl', format := 'newline_delimited',
    hive_partitioning := true, union_by_name := true, filename := true)),
run AS (
  SELECT parent_system, parent, luna,
    (array_agg(thread_id) FILTER (thread_id IS NOT NULL))[1] AS thread_id,
    len(array_agg(type) FILTER (type = 'turn.completed')) AS turns,
    sum(usage.input_tokens) AS input_tokens, sum(usage.cached_input_tokens) AS cached_tokens,
    sum(usage.output_tokens) AS output_tokens, sum(usage.reasoning_output_tokens) AS reasoning_tokens,
    (array_agg(item.text) FILTER (item.type = 'agent_message'))[-1][:300] AS last_message
  FROM ev GROUP BY ALL),
done AS (
  -- read_csv(path, delim, quote, escape, header, columns, hive_partitioning; others default)
  SELECT parent_system, parent, luna, line::INTEGER AS exit_code
  FROM read_csv('~/.duck/luna_runs/*/*/*/exit', delim := chr(1), quote := '', escape := '',
    header := false, columns := {'line': 'VARCHAR'}, hive_partitioning := true)),
brief AS (
  SELECT parent_system, parent, luna, (array_agg(line))[1][:160] AS brief
  FROM read_csv('~/.duck/luna_runs/*/*/*/brief.md', delim := chr(1), quote := '', escape := '',
    header := false, columns := {'line': 'VARCHAR'}, hive_partitioning := true)
  GROUP BY ALL),
live AS (
  SELECT session_id AS thread_id, array_agg(DISTINCT model) FILTER (model IS NOT NULL) AS models,
    array_agg(DISTINCT reasoning_effort) FILTER (reasoning_effort IS NOT NULL) AS efforts,
    [min(ts), max(ts)] AS min_max_ts_arr,
    len(array_agg(tool_use_id) FILTER (tool_use_id IS NOT NULL)) AS tool_rows
  FROM agent.stream WHERE system = 'codex' AND originator = 'codex_exec' GROUP BY ALL),
parent AS (
  SELECT session_id AS parent, (array_agg(project_path ORDER BY ts DESC))[1] AS parent_project
  FROM agent.stream WHERE system = 'claude' GROUP BY ALL)
SELECT r.parent_system, r.parent, p.parent_project, r.luna, r.thread_id, b.brief, l.models, l.efforts,
  CASE WHEN d.exit_code IS NOT NULL THEN 'exited ' || d.exit_code
       WHEN now() - l.min_max_ts_arr[2] > INTERVAL 10 MINUTE THEN 'quiet (stopped or stuck)'
       ELSE 'running' END AS state,
  l.min_max_ts_arr, l.tool_rows, r.turns, r.input_tokens, r.cached_tokens, r.output_tokens,
  r.reasoning_tokens, r.last_message
FROM run r
LEFT JOIN done d USING (parent_system, parent, luna)
LEFT JOIN brief b USING (parent_system, parent, luna)
LEFT JOIN live l USING (thread_id)
LEFT JOIN parent p USING (parent)
ORDER BY l.min_max_ts_arr[1] DESC NULLS LAST;

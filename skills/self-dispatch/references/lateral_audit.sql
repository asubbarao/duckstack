-- Where is LATERAL still used? One relation over three sources: agents' SQL tool calls (stream.blocks), every
-- statement dev itself ran (meta.query_metrics, including self-dispatched ones, with latency), and the .sql files on
-- duckstack main. A statement is flagged for each LATERAL table function it invokes (sitting_duck `invocation`
-- nodes joined to duckdb_functions: *_each, read_lines_lateral, json_each, json_tree) and, when it invokes none,
-- for the bare LATERAL keyword. The sql_lateral_not_allowlisted hook warns at call time; this finds what got through.
-- Each use is rewritten as self-dispatch: ../SKILL.md. Window: 1 day (dev's 2-min deadline).
WITH lateral_functions AS (
  SELECT DISTINCT function_name FROM duckdb_functions()
  WHERE function_type = 'table' AND CASE WHEN ends_with(function_name, '_each') THEN true ELSE function_name IN ('read_lines_lateral', 'json_each', 'json_tree') END
), tool_calls AS (
  SELECT 'tool_call' AS source, left(session_id, 8) AS place, tool_command AS sql, NULL::DOUBLE AS latency_s
  FROM stream.blocks WHERE block_type = 'tool_use' AND NOT is_repeat AND timestamp > now() - INTERVAL 1 DAY AND contains(tool_name, '__query')
), server_queries AS (
  SELECT 'server_query' AS source, connection_id::VARCHAR AS place, query AS sql, latency_s
  FROM meta.query_metrics WHERE timestamp > now() - INTERVAL 1 DAY
), repo_files AS (
  SELECT 'duckstack_main' AS source, replace(filename, 'git:///Users/aloksubbarao/duckdb-skills/', '') AS place, content AS sql, NULL::DOUBLE AS latency_s
  FROM read_text(['git:///Users/aloksubbarao/duckdb-skills/server/*.sql@origin/main', 'git:///Users/aloksubbarao/duckdb-skills/hooks/*.sql@origin/main', 'git:///Users/aloksubbarao/duckdb-skills/skills/*/references/*.sql@origin/main'])
), statements AS (
  SELECT *, md5(source || place || sql) AS statement_id, contains(upper(sql), 'LATERAL') AS has_lateral_keyword
  FROM (FROM tool_calls UNION ALL BY NAME FROM server_queries UNION ALL BY NAME FROM repo_files)
  WHERE len(list_filter(['LATERAL', '_EACH('], p -> contains(upper(sql), p))) > 0
), invocations AS (
  SELECT statement_id, unnest(list_distinct([n.name FOR n IN parse_ast_list(sql, 'sql') IF n.type = 'invocation'])) AS invoked FROM statements
), function_uses AS (
  SELECT statements.source, statements.place, statements.latency_s, invocations.invoked AS lateral_use, statements.statement_id
  FROM invocations JOIN lateral_functions ON lateral_functions.function_name = invocations.invoked JOIN statements USING (statement_id)
), keyword_uses AS (
  SELECT source, place, latency_s, 'LATERAL keyword' AS lateral_use, statement_id
  FROM statements ANTI JOIN function_uses USING (statement_id) WHERE has_lateral_keyword
)
SELECT source, lateral_use, len(list(DISTINCT place)) AS places, len(list(DISTINCT statement_id)) AS statements,
       round(sum(latency_s), 1) AS latency_s, list(DISTINCT place)[1:3] AS sample_places
FROM (FROM function_uses UNION ALL BY NAME FROM keyword_uses)
GROUP BY ALL ORDER BY source, statements DESC

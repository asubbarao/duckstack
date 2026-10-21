-- Where is LATERAL still used? One relation over three sources: agents' SQL tool calls (stream.blocks) and every
-- statement dev itself ran (meta.query_metrics, including self-dispatched ones, with latency) over the last day, and
-- the .sql files on duckstack main, read one glob per self-dispatched statement. A statement is flagged for each
-- LATERAL table function it invokes (sitting_duck `invocation` nodes joined to duckdb_functions: *_each,
-- read_lines_lateral, json_tree) and, when it invokes none, for the bare LATERAL keyword. The
-- sql_lateral_not_allowlisted hook warns at call time; this finds what got through. LATERAL is allowed; each use is a
-- candidate to measure against the self-dispatch form (../SKILL.md), which usually wins.
WITH lateral_functions AS (
  SELECT DISTINCT function_name FROM duckdb_functions()
  WHERE function_type = 'table' AND list_bool_or([ends_with(function_name, '_each'), list_contains(['read_lines_lateral', 'json_tree'], function_name)])
), repo_globs AS (
  SELECT 'git:///Users/aloksubbarao/duckdb-skills/' AS repo, '@origin/main' AS ref, pattern
  FROM UNNEST(['server/*.sql', 'hooks/*.sql', 'skills/*/references/*.sql']) AS t(pattern)
), repo_statements AS (
  SELECT pattern, tera_render($t$SELECT replace(filename, '{{ repo }}', '') AS place, content AS sql FROM read_text('{{ repo }}{{ pattern }}{{ ref }}')$t$,
                           repo_globs::JSON, autoescape := false) AS sql
  FROM repo_globs
), repo_reads AS (
  SELECT array_agg(selfdispatch(sql)) AS receipts FROM repo_statements
), logged_sql AS (
  SELECT * EXCLUDE (timestamp) FROM (
    SELECT 'tool_call' AS source, left(session_id, 8) AS place, tool_command AS sql, timestamp
    FROM stream.blocks WHERE block_type = 'tool_use' AND NOT is_repeat AND contains(tool_name, '__query')
    UNION ALL BY NAME
    SELECT 'server_query' AS source, connection_id::VARCHAR AS place, query AS sql, latency_s, timestamp FROM meta.query_metrics
  ) WHERE timestamp > now() - INTERVAL 1 DAY
), statements AS (
  SELECT *, hash(source, place, sql) AS statement_id, contains(upper(sql), 'LATERAL') AS has_lateral_keyword
  FROM (FROM logged_sql
        UNION ALL BY NAME
        SELECT 'duckstack_main' AS source, row ->> 'place' AS place, row ->> 'sql' AS sql
        FROM repo_reads CROSS JOIN UNNEST(receipts) AS t(receipt) CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(row))
  WHERE string_contains_any(upper(sql), ['LATERAL', '_EACH('])
), invocations AS (
  SELECT statements.* EXCLUDE (sql), invoked
  FROM statements CROSS JOIN UNNEST(list_distinct([n.name FOR n IN parse_ast_list(sql, 'sql') IF n.type = 'invocation'])) AS t(invoked)
), function_uses AS (
  SELECT invocations.* EXCLUDE (invoked), invoked AS lateral_use
  FROM invocations SEMI JOIN lateral_functions ON lateral_functions.function_name = invocations.invoked
), keyword_uses AS (
  SELECT statements.* EXCLUDE (sql), 'LATERAL keyword' AS lateral_use
  FROM statements ANTI JOIN function_uses USING (statement_id) WHERE has_lateral_keyword
)
SELECT source, lateral_use, len(list(DISTINCT place)) AS places, len(list(DISTINCT statement_id)) AS statements,
       round(sum(latency_s), 1) AS latency_s, list(DISTINCT place)[1:3] AS sample_places
FROM (FROM function_uses UNION ALL BY NAME FROM keyword_uses)
GROUP BY ALL ORDER BY source, statements DESC

-- Every Claude and Codex tool call in agent.lines, once, with its result and what it ran: the shell commands (Bash, a
-- Codex exec_command, or a shellfs reader inside SQL), the SQL (Claude's, or sent from a Codex script), and in those the
-- programs, functions and tables. parser_tools and sitting_duck both run on every statement; each sees what the other misses.
WITH recent AS (
    SELECT e.session, (l.timestamp ->> '$')::TIMESTAMPTZ AS ts, l.type ->> '$' AS line_type, l.message, l.payload,
           CASE WHEN contains(l.transcript, '/.codex/') THEN 'codex' ELSE 'claude' END AS source
    FROM agent.lines AS l JOIN agent.entries AS e ON e.path = l.transcript
    WHERE (l.timestamp ->> '$')::TIMESTAMPTZ > now() - INTERVAL 2 DAY
), claude_blocks AS (
    SELECT session, ts, source, unnest(message -> '$.content[*]') AS block
    FROM recent WHERE line_type IN ('assistant', 'user') AND json_type(message -> 'content') = 'ARRAY'
), claude_fields AS (
    SELECT session, ts, source, block ->> 'type' AS block_type, coalesce(block ->> 'id', block ->> 'tool_use_id') AS call_id,
           block ->> 'name' AS tool_name, block -> 'input' AS input, block -> 'content' AS output, block ->> 'is_error' AS is_error
    FROM claude_blocks
), codex_fields AS (
    SELECT session, ts, source, payload ->> 'type' AS payload_type, payload ->> 'call_id' AS call_id, payload ->> 'name' AS tool_name,
           TRY_CAST(payload ->> 'arguments' AS JSON) AS arguments, payload ->> 'input' AS custom_input, payload -> 'output' AS output
    FROM recent WHERE line_type = 'response_item'
), calls AS (
    SELECT session, ts, source, call_id, tool_name,
           CASE WHEN input ->> 'command' IS NOT NULL THEN 'shell'
                WHEN coalesce(input ->> 'sql', input ->> 'statement') IS NOT NULL THEN 'sql' ELSE 'json' END AS input_format,
           coalesce(input ->> 'command', input ->> 'sql', input ->> 'statement', input::VARCHAR) AS input
    FROM claude_fields WHERE block_type = 'tool_use'
    UNION ALL
    SELECT session, ts, source, call_id, tool_name,
           CASE WHEN payload_type = 'custom_tool_call' THEN 'javascript'
                WHEN coalesce(arguments ->> 'cmd', arguments ->> 'command') IS NOT NULL THEN 'shell'
                WHEN arguments ->> 'sql' IS NOT NULL THEN 'sql' ELSE 'json' END,
           coalesce(custom_input, arguments ->> 'cmd', arguments ->> 'command', arguments ->> 'sql', arguments::VARCHAR)
    FROM codex_fields WHERE payload_type IN ('function_call', 'custom_tool_call')
), results AS (
    SELECT call_id, ts AS result_ts, coalesce(is_error::BOOLEAN, false) AS is_error, output::VARCHAR AS output
    FROM claude_fields WHERE block_type = 'tool_result'
    UNION ALL
    SELECT call_id, ts, false, output::VARCHAR FROM codex_fields WHERE payload_type IN ('function_call_output', 'custom_tool_call_output')
), first_calls AS (
    SELECT * FROM calls QUALIFY row_number() OVER (PARTITION BY call_id ORDER BY ts) = 1
), first_results AS (
    SELECT * FROM results QUALIFY row_number() OVER (PARTITION BY call_id ORDER BY result_ts) = 1
),

-- What each call ran. A Codex script's cmd and sql arguments are pairs in its JavaScript parse.
script_nodes AS (
    SELECT call_id, unnest(parse_ast_list(input, 'javascript')) AS node FROM first_calls WHERE input_format = 'javascript'
), script_pairs AS (
    SELECT k.call_id, k.node.name AS key, trim(v.node.peek, '"`''') AS value
    FROM script_nodes AS k JOIN script_nodes AS v ON v.call_id = k.call_id AND v.node.parent_id = k.node.parent_id
    WHERE k.node.type = 'property_identifier' AND k.node.name IN ('cmd', 'sql', 'statement')
      AND v.node.type IN ('string', 'template_string')
), sql_texts AS (
    SELECT call_id, input AS sql_text FROM first_calls WHERE input_format = 'sql'
    UNION ALL
    SELECT call_id, value FROM script_pairs WHERE key IN ('sql', 'statement')
), statements AS (
    -- DuckDB prints each statement back in its own words (FROM-first becomes SELECT * FROM); what it cannot parse is
    -- kept whole for sitting_duck
    SELECT call_id, CASE WHEN is_parsable(sql_text) THEN parse_statements(sql_text) ELSE [sql_text] END AS statement_list
    FROM sql_texts
), statement_rows AS (
    SELECT call_id, unnest(statement_list) AS statement FROM statements
), sql_nodes AS (
    SELECT call_id, statement, unnest(parse_ast_list(statement, 'sql')) AS node FROM statement_rows
), shell_texts AS (
    SELECT call_id, 'bash' AS route, input AS command FROM first_calls WHERE input_format = 'shell'
    UNION ALL
    SELECT call_id, 'codex exec_command', value FROM script_pairs WHERE key = 'cmd'
    UNION ALL
    -- a shellfs reader's command: a string literal in the SQL that ends with a pipe
    SELECT call_id, 'shellfs on dev', rtrim(trim(node.name, ''''), ' |') FROM sql_nodes WHERE node.type = 'literal' AND ends_with(trim(node.name, ''''), '|')
), shell_nodes AS (
    SELECT call_id, route, unnest(parse_ast_list(command, 'bash')) AS node FROM shell_texts
), ran AS (
    SELECT call_id, list(DISTINCT route) AS shell_routes,
           list_filter(list(DISTINCT CASE WHEN node.type = 'command_name' THEN node.peek END), x -> x IS NOT NULL) AS programs
    FROM shell_nodes GROUP BY call_id
), sql_names AS (
    SELECT call_id,
           list_filter(list(DISTINCT CASE WHEN node.type = 'invocation' THEN lower(node.name) END), x -> x IS NOT NULL) AS sd_functions,
           list_filter(list(DISTINCT CASE WHEN node.type = 'object_reference' THEN node.name END), x -> x IS NOT NULL) AS sd_tables,
           list(DISTINCT statement) AS sql_statements
    FROM sql_nodes GROUP BY call_id
), parser_tools_names AS (
    SELECT call_id, flatten(list(parse_function_names(statement))) AS pt_functions,
           flatten(list(list_transform(parse_tables(statement), t -> t."table"))) AS pt_tables
    FROM statement_rows WHERE is_parsable(statement) GROUP BY call_id
)
SELECT c.source, c.session, c.ts, c.call_id, c.tool_name, c.input_format, c.input,
       r.result_ts, r.is_error, r.output, s.sql_statements,
       list_distinct(list_concat(coalesce(s.sd_functions, []), coalesce(list_transform(p.pt_functions, f -> lower(f)), []))) AS functions,
       list_distinct(list_concat(coalesce(s.sd_tables, []), coalesce(p.pt_tables, []))) AS tables,
       coalesce(x.shell_routes, []) AS shell_routes, coalesce(x.programs, []) AS programs
FROM first_calls AS c
LEFT JOIN first_results AS r USING (call_id)
LEFT JOIN sql_names AS s USING (call_id)
LEFT JOIN parser_tools_names AS p USING (call_id)
LEFT JOIN ran AS x USING (call_id)

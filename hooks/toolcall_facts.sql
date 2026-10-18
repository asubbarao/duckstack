-- toolcall_facts: one row per agent tool call (all tools), the parsed facts the hook checks read.
-- Inputs, defined by the caller before this file:
--   tc_src(call_id, session, ts, subagent, tool_name, input, next_prompt_corrects)   one row per call
--   bash_src(<wave-1 parse-bash row: call_id, parse_ok, effective_commands, command_details, ...>)
-- Corpus: tc_src = toolcalls.parquet, bash_src = the signed toolcall_bash_ast parquet (corpus_sources.sql).
-- Hook:   tc_src = the PreToolUse JSON on stdin, bash_src = the same parse-bash views over that one command.
-- SQL facts are computed here from text, for dev-tool SQL, SQL embedded in Bash (duckdb -c / heredoc /
-- positional) and .sql files written or edited, with the parsers wave 1 used: sitting_duck 'duckdb' splits
-- statements, json_serialize_sql gives the AST, parser_tools.is_parsable gates it.
LOAD sitting_duck;
LOAD parser_tools;
LOAD tera;

CREATE OR REPLACE VIEW tc_input AS
WITH j AS (SELECT *, input::JSON AS input_json FROM tc_src)
SELECT call_id, session, ts, subagent, tool_name, next_prompt_corrects, input_json,
       coalesce(input_json ->> 'file_path', input_json ->> 'path') AS file_path,
       input_json ->> 'content' AS write_content,
       input_json ->> 'new_string' AS edit_new_string,
       input_json ->> 'model' AS agent_model,
       input_json ->> 'subagent_type' AS agent_subagent_type,
       input_json ->> 'prompt' AS agent_prompt,
       input_json ->> 'skill' AS skill_name,
       input_json ->> 'title' AS linear_title,
       coalesce(input_json ->> 'channel_id', input_json ->> 'channel') AS slack_channel
FROM j;

CREATE OR REPLACE VIEW tc_paths AS
SELECT call_id, file_path,
       parse_filename(file_path) AS file_name,
       substr(parse_filename(file_path), length(parse_filename(file_path, true)) + 1) AS file_ext,
       parse_path(file_path) AS file_path_parts
FROM tc_input WHERE file_path IS NOT NULL;

-- Every SQL text a call carries.
CREATE OR REPLACE VIEW sql_texts AS
SELECT call_id, 'tool' AS sql_source, 0::BIGINT AS program_index,
       coalesce(input_json ->> 'sql', input_json ->> 'statement', input_json ->> 'query', input_json ->> 'rows_sql') AS sql_text
FROM tc_input
WHERE tool_name IN ('mcp__dev__query', 'mcp__dev__execute', 'mcp__dev__query_no_limit', 'mcp__dev__query_with_limit',
                    'mcp__dev__sql', 'mcp__dev__self_dispatch')
UNION ALL
SELECT b.call_id, 'embedded', e.idx, e.prog.program
FROM bash_src b CROSS JOIN UNNEST(b.embedded_programs) WITH ORDINALITY AS e(prog, idx)
WHERE e.prog.interpreter = 'duckdb'
UNION ALL
-- CLI dot commands (.read, .output) are not SQL, and one of them fails the parse of the whole file.
SELECT i.call_id, 'file', 0,
       tera_render($t${{ lines | join(sep="
") }}$t$, json_object('lines', list_filter(string_split(coalesce(i.write_content, i.edit_new_string), E'\n'), l -> NOT starts_with(ltrim(l), '.'))),
                   autoescape := false)
FROM tc_input i JOIN tc_paths p ON p.call_id = i.call_id
WHERE i.tool_name IN ('Write', 'Edit') AND p.file_ext = '.sql';

-- One row per statement: DuckDB's own statement split and canonical text.
CREATE OR REPLACE VIEW sql_statements AS
WITH parsed_texts AS (
  -- Each text is parsed once; only the statement nodes (depth 0-1) are kept.
  SELECT *, list_filter(parse_ast_list(sql_text, 'duckdb'), x -> list_contains([0, 1], x.depth)) AS top_nodes
  FROM sql_texts WHERE sql_text IS NOT NULL
), whole_texts AS (
  SELECT call_id, sql_source, program_index, sql_text, top_nodes,
         list_contains([x.type FOR x IN top_nodes], 'parse_error') AS parse_failed
  FROM parsed_texts
), split_pieces AS (
  -- One statement sitting_duck's parser rejects (quackapi's CREATE ROUTE) fails the whole text, so such a text is
  -- split at ';' line ends and each statement is read on its own.
  SELECT whole_texts.call_id, whole_texts.sql_source, whole_texts.program_index, split.piece, split.piece_no,
         list_filter(parse_ast_list(split.piece, 'duckdb'), x -> list_contains([0, 1], x.depth)) AS top_nodes
  FROM whole_texts
  CROSS JOIN UNNEST([concat(p, ';') FOR p IN string_split(whole_texts.sql_text, E';\n')]) WITH ORDINALITY AS split(piece, piece_no)
  WHERE whole_texts.parse_failed
), pieces AS (
  SELECT call_id, sql_source, program_index, piece, piece_no, top_nodes,
         list_contains([x.type FOR x IN top_nodes], 'parse_error') AS parse_failed
  FROM split_pieces
), nodes AS (
  SELECT call_id, sql_source, program_index, 1 AS piece_no, unnest(top_nodes) AS n
  FROM whole_texts WHERE NOT parse_failed
  UNION ALL
  -- A statement the parser still rejects is read from its query, the text after its first ' AS '
  -- (CREATE ROUTE / CREATE MIDDLEWARE ... AS SELECT).
  SELECT call_id, sql_source, program_index, piece_no,
         unnest(CASE WHEN parse_failed
                     -- AS often ends its line, so whitespace is matched as spaces (translate keeps every position)
                     THEN list_filter(parse_ast_list(substr(piece, instr(upper(translate(piece, E'\n\t\r', '   ')), ' AS ') + 4), 'duckdb'), x -> x.depth = 1)
                     ELSE top_nodes END) AS n
  FROM pieces)
SELECT call_id, sql_source, program_index, n.type AS statement_kind, n.peek AS statement_sql,
       [upper(w) FOR w IN string_split(trim(n.peek), ' ') IF w <> ''][1:5] AS head_words,
       len(string_split(n.peek, E'\n')) AS statement_lines,
       -- json_serialize_sql takes only a SELECT; a view's query is the text after its first ' AS '.
       CASE n.type WHEN 'select_statement'
            THEN json_serialize_sql(n.peek, skip_null := true, skip_empty := true, skip_default := true) -> 'statements' -> 0
            WHEN 'create_view'
            THEN json_serialize_sql(substr(n.peek, instr(upper(translate(n.peek, E'\n\t\r', '   ')), ' AS ') + 4), skip_null := true, skip_empty := true, skip_default := true) -> 'statements' -> 0 END AS ast,
       row_number() OVER (PARTITION BY call_id, sql_source, program_index ORDER BY piece_no, n.node_id) AS statement_no
FROM nodes WHERE n.depth = 1;

-- AST object nodes with the classification wave 1 used.
CREATE OR REPLACE VIEW sql_nodes AS
SELECT s.call_id, s.sql_source, s.program_index, s.statement_no, t.id AS node_id, t.key, t.value AS v,
       t.value ->> 'class' AS cls, t.value ->> 'type' AS typ,
       CASE WHEN (t.value ->> 'class') IN ('FUNCTION', 'WINDOW') AND t.key IS DISTINCT FROM 'function' THEN t.value ->> 'function_name' END AS fn,
       CASE WHEN (t.value ->> 'type') = 'TABLE_FUNCTION' THEN t.value -> 'function' ->> 'function_name' END AS tfn,
       t.value -> 'right' -> 'function' ->> 'function_name' AS join_right_fn,
       CASE WHEN (t.value ->> 'type') = 'JOIN' AND (t.value ->> 'class') IS NULL THEN
            -- CROSS JOIN UNNEST(...) WITH ORDINALITY also comes without a query_location; it is a cross join.
            CASE WHEN (t.value ->> 'ref_type') = 'CROSS' AND (t.value -> 'query_location') IS NULL
                      AND join_right_fn IS DISTINCT FROM 'unnest' THEN 'COMMA'
                 WHEN (t.value ->> 'ref_type') = 'REGULAR' THEN t.value ->> 'join_type'
                 ELSE t.value ->> 'ref_type' END END AS join_kind,
       t.value -> 'right' ->> 'type' AS join_right_type,
       [lower(c ->> 'class') FOR c IN json_extract(t.value, '$.right.function.children[*]')] AS join_right_arg_kinds,
       [CASE WHEN (c ->> 'class') = 'FUNCTION' THEN c ->> 'function_name'
             WHEN (c ->> 'class') = 'CAST' AND (c -> 'child' ->> 'class') = 'CONSTANT' THEN 'constant'
             ELSE lower(c ->> 'class') END
        FOR c IN CASE WHEN (t.value ->> 'type') = 'TABLE_FUNCTION' THEN json_extract(t.value, '$.function.children[*]') ELSE json_extract(t.value, '$.children[*]') END] AS arg_kinds,
       -- Constant arguments, and the constants inside a list argument (read_text(['a', 'b'])).
       -- json_serialize_sql drops an empty string's value; a non-null constant without one is ''.
       [coalesce(c -> 'value' ->> 'value', CASE WHEN (c -> 'value' ->> 'is_null') = 'false' THEN '' END)
        FOR c IN flatten([CASE WHEN (a ->> 'function_name') = 'list_value' THEN json_extract(a, '$.children[*]') ELSE [a] END
                          FOR a IN CASE WHEN (t.value ->> 'type') = 'TABLE_FUNCTION' THEN json_extract(t.value, '$.function.children[*]') ELSE json_extract(t.value, '$.children[*]') END])
        IF (c ->> 'class') = 'CONSTANT'] AS literal_args,
       -- Operators that read like functions (COALESCE, IN, NOT) keep their AST type as a name.
       CASE WHEN (t.value ->> 'class') = 'OPERATOR' THEN lower(t.value ->> 'type') END AS op
FROM sql_statements s CROSS JOIN LATERAL json_tree(s.ast) AS t
WHERE s.ast IS NOT NULL AND t.type = 'OBJECT';

-- Concatenation chains: '||' nodes counted under each '||' root (wave 1's concat_chain_max).
CREATE OR REPLACE VIEW sql_concat AS
WITH roots AS (
  SELECT n.call_id, n.sql_source, n.program_index, n.statement_no, n.node_id, len(list(s.value)) AS ops
  FROM sql_nodes n CROSS JOIN LATERAL json_tree(n.v) AS s
  WHERE n.fn = '||' AND s.type = 'OBJECT' AND (s.value ->> 'function_name') = '||'
  GROUP BY ALL)
SELECT call_id, sql_source, program_index, statement_no, max(ops) + 1 AS concat_chain_max FROM roots GROUP BY ALL;

CREATE OR REPLACE VIEW sql_statement_facts AS
WITH node_facts AS (
  SELECT call_id, sql_source, program_index, statement_no,
         list_sort(list_distinct(list(fn))) AS functions_called,
         list_filter(list(CASE WHEN coalesce(fn, op) IS NOT NULL THEN {'name': coalesce(fn, op), 'args': arg_kinds, 'literals': literal_args} END), x -> x IS NOT NULL) AS function_calls,
         flatten(list_filter(list(CASE WHEN key = 'cte_map' THEN [e ->> 'key' FOR e IN json_extract(v, '$.map[*]')] END), x -> x IS NOT NULL)) AS cte_names,
         list_filter(list(CASE WHEN tfn IS NOT NULL THEN {'name': tfn, 'args': arg_kinds, 'literals': literal_args} END), x -> x IS NOT NULL) AS table_function_calls,
         -- each shellfs command (a table-function literal ending in '|') parsed as bash: the programs it runs
         -- (basenames, $(...) included) and its words, so checks match executables, not quoted arguments
         flatten(list_filter(list(CASE WHEN tfn IS NOT NULL THEN
             [{'commands': [parse_filename(n.peek) FOR n IN parse_ast_list(rtrim(rtrim(l), '|'), 'bash') IF n.type = 'command_name'],
               'words': [n.peek FOR n IN parse_ast_list(rtrim(rtrim(l), '|'), 'bash') IF n.type = 'word']}
              FOR l IN literal_args IF ends_with(rtrim(l), '|')] END), x -> x IS NOT NULL)) AS shellfs_pipes,
         bool_or(template.file IS NOT NULL) AS uses_canonical_template,
         bool_or(fn = 'count_star') AS has_count_star,
         bool_or((v -> 'filter') IS NOT NULL AND cls IN ('FUNCTION', 'WINDOW')) AS has_filter_clause,
         bool_or(typ = 'EXPRESSION_LIST') AS has_values_clause,
         bool_or(typ = 'RECURSIVE_CTE_NODE') AS has_recursive_cte,
         bool_or(key = 'cte_map' AND list_contains([(e -> 'value' ->> 'materialized') FOR e IN json_extract(v, '$.map[*]')], 'CTE_MATERIALIZE_ALWAYS')) AS has_materialized_cte,
         count(CASE WHEN typ = 'CONJUNCTION_OR' THEN 1 END) AS or_node_count,
         bool_or(typ = 'CONJUNCTION_OR' AND list_has_any(arg_kinds, ['~~', '!~~', '~~*', '!~~*', 'contains', 'glob', 'starts_with', 'ends_with', 'prefix', 'suffix', 'like_escape', 'ilike_escape'])) AS has_or_of_patterns,
         list_filter(list(CASE WHEN typ = 'LIMIT_MODIFIER' THEN (v -> 'limit' -> 'value' ->> 'value')::BIGINT END), x -> x IS NOT NULL) AS limit_values,
         list_sort(list_distinct(list(join_kind))) AS join_types,
         bool_or(join_kind = 'COMMA') AS has_comma_join,
         bool_or(join_kind = 'CROSS' AND join_right_fn = 'unnest') AS has_unnest_cross_join,
         bool_or(join_kind = 'CROSS' AND join_right_fn IS DISTINCT FROM 'unnest' AND join_right_type IS DISTINCT FROM 'TABLE_FUNCTION') AS has_cross_join_not_unnest,
         bool_or(join_kind = 'CROSS' AND join_right_type = 'TABLE_FUNCTION' AND join_right_fn IS DISTINCT FROM 'unnest') AS has_lateral_function_join,
         -- a LEFT join whose right side is unnest or a table function fed by a column (correlated, lateral)
         bool_or(join_kind = 'LEFT' AND join_right_type = 'TABLE_FUNCTION' AND CASE WHEN join_right_fn = 'unnest' THEN true ELSE list_contains(join_right_arg_kinds, 'column_ref') END) AS has_left_join_lateral,
         bool_or(join_kind IS NOT NULL AND 'CONSTANT' IN (v -> 'condition' ->> 'class', v -> 'condition' -> 'child' ->> 'class')) AS has_join_on_constant,
         bool_or(typ = 'SELECT_NODE' AND list_contains([(c ->> 'class') = 'SUBQUERY' AND (c ->> 'subquery_type') = 'SCALAR' FOR c IN (v -> 'select_list')::JSON[]], true)) AS has_scalar_subquery_in_select,
         bool_or(typ = 'SELECT_NODE' AND (v -> 'qualify') IS NOT NULL) AS has_qualify,
         list_filter(list(CASE WHEN join_kind = 'CROSS' AND join_right_type = 'TABLE_FUNCTION' THEN join_right_fn END), x -> x IS NOT NULL) AS lateral_functions
  FROM sql_nodes   -- a tera_render naming a file in the templates folder; one call names one template, so no fan-out
  LEFT JOIN glob('~/.duck/deploy/skills/self-dispatch/templates/*.tera') AS template
    ON fn = 'tera_render' AND list_contains(literal_args, parse_filename(template.file))
  GROUP BY ALL)
SELECT s.call_id, s.sql_source, s.program_index, s.statement_no, s.statement_kind, s.head_words, s.statement_lines,
       s.ast IS NOT NULL AS has_ast,
       coalesce(f.functions_called, []) AS functions_called,
       coalesce(f.function_calls, []) AS function_calls,
       coalesce(f.table_function_calls, []) AS table_function_calls,
       coalesce(f.shellfs_pipes, []) AS shellfs_pipes,
       coalesce(f.uses_canonical_template, false) AS uses_canonical_template,       coalesce(f.cte_names, []) AS cte_names,
       coalesce(f.has_count_star, false) AS has_count_star,
       coalesce(f.has_filter_clause, false) AS has_filter_clause,
       coalesce(f.has_values_clause, false) AS has_values_clause,
       coalesce(f.has_recursive_cte, false) AS has_recursive_cte,
       coalesce(f.has_materialized_cte, false) AS has_materialized_cte,
       coalesce(f.or_node_count, 0) AS or_node_count,
       coalesce(f.has_or_of_patterns, false) AS has_or_of_patterns,
       coalesce(f.limit_values, []) AS limit_values,
       coalesce(f.join_types, []) AS join_types,
       coalesce(f.has_comma_join, false) AS has_comma_join,
       coalesce(f.has_unnest_cross_join, false) AS has_unnest_cross_join,
       coalesce(f.has_cross_join_not_unnest, false) AS has_cross_join_not_unnest,
       coalesce(f.has_lateral_function_join, false) AS has_lateral_function_join,
       coalesce(f.has_left_join_lateral, false) AS has_left_join_lateral,
       coalesce(f.has_join_on_constant, false) AS has_join_on_constant,
       coalesce(f.has_scalar_subquery_in_select, false) AS has_scalar_subquery_in_select,
       coalesce(f.has_qualify, false) AS has_qualify,
       coalesce(f.lateral_functions, []) AS lateral_functions,
       coalesce(c.concat_chain_max, 0) AS concat_chain_max
FROM sql_statements s
LEFT JOIN node_facts f USING (call_id, sql_source, program_index, statement_no)
LEFT JOIN sql_concat c USING (call_id, sql_source, program_index, statement_no);

-- Per call: the statements' facts folded into lists, counts and any-statement booleans.
CREATE OR REPLACE VIEW sql_call_facts AS
WITH texts AS (
  SELECT call_id, list_sort(list_distinct(list(sql_source))) AS sql_sources,
         bool_and(coalesce(is_parsable(sql_text), false)) AS sql_parse_ok
  FROM sql_texts WHERE sql_text IS NOT NULL GROUP BY ALL),
stmts AS (
  SELECT call_id,
         len(list(statement_no)) AS sql_statement_count,
         list(statement_kind) AS sql_statement_kinds,
         list(head_words) AS sql_heads,
         list_distinct(list(head_words[1])) AS sql_verbs,
         max(statement_lines) AS sql_max_statement_lines,
         list_sort(list_distinct(flatten(list(functions_called)))) AS sql_functions,
         flatten(list(function_calls)) AS sql_function_calls,
         flatten(list(table_function_calls)) AS sql_table_function_calls,
         list_sort(list_distinct(flatten(list([t.name FOR t IN table_function_calls])))) AS sql_table_functions,
         flatten(list(shellfs_pipes)) AS sql_shellfs_pipes,
         list_distinct(flatten([p.commands FOR p IN flatten(list(shellfs_pipes))])) AS sql_shellfs_commands,
         bool_or(uses_canonical_template) AS sql_uses_canonical_template,
         list_distinct(flatten(list(cte_names))) AS sql_cte_names,
         bool_or(has_count_star) AS sql_has_count_star,
         bool_or(has_filter_clause) AS sql_has_filter_clause,
         bool_or(has_values_clause) AS sql_has_values_clause,
         bool_or(list_contains(limit_values, 1)) AS sql_has_limit_1,
         bool_or(has_recursive_cte) AS sql_has_recursive_cte,
         bool_or(has_materialized_cte) AS sql_has_materialized_cte,
         sum(or_node_count) AS sql_or_node_count,
         bool_or(has_or_of_patterns) AS sql_has_or_of_patterns,
         bool_or(has_comma_join) AS sql_has_comma_join,
         bool_or(has_cross_join_not_unnest) AS sql_has_cross_join_not_unnest,
         bool_or(has_unnest_cross_join) AS sql_has_unnest_cross_join,
         bool_or(has_lateral_function_join) AS sql_has_lateral_function_join,
         bool_or(has_left_join_lateral) AS sql_has_left_join_lateral,
         bool_or(has_join_on_constant) AS sql_has_join_on_constant,
         bool_or(has_scalar_subquery_in_select) AS sql_has_scalar_subquery_in_select,
         bool_or(has_qualify) AS sql_has_qualify,         list_distinct(flatten(list(lateral_functions))) AS sql_lateral_functions,
         max(concat_chain_max) AS sql_concat_chain_max
  FROM sql_statement_facts GROUP BY ALL)
SELECT t.call_id, t.sql_sources, t.sql_parse_ok, s.* EXCLUDE (call_id)
FROM texts t LEFT JOIN stmts s USING (call_id);

-- Bash facts per call, from the parse-bash row.
CREATE OR REPLACE VIEW bash_call_facts AS
SELECT call_id,
       parse_ok AS bash_parse_ok,
       commands AS bash_raw_commands,
       effective_commands AS bash_commands,
       command_details AS bash_command_details,
       [d.eff_exe FOR d IN command_details IF d.in_pipeline] AS bash_pipeline_commands,
       max_pipeline_length::BIGINT AS bash_max_pipeline_length,
       loop_count::BIGINT AS bash_loop_count,
       uses_sleep AS bash_uses_sleep,
       launches_background AS bash_launches_background,
       background_commands AS bash_background_commands,
       run_in_background AS bash_run_in_background,
       heredoc_interpreters AS bash_heredoc_interpreters,
       embedded_interpreters AS bash_embedded_interpreters,
       writes_files AS bash_writes_files,
       git_subcommands AS bash_git_subcommands,
       gh_subcommands AS bash_gh_subcommands,
       duckdb_databases AS bash_duckdb_databases,
       curl_urls AS bash_curl_urls,
       [parse_uri(u) FOR u IN curl_urls] AS bash_curl_uris,
       flatten([[w[i + 1] FOR w2, i IN w IF w2 IN ('-R', '--repo')] FOR w IN command_words IF parse_filename(w[1]) = 'gh']) AS bash_gh_repos
FROM bash_src;

CREATE OR REPLACE VIEW toolcall_facts AS
SELECT i.call_id, i.session, i.ts, i.subagent, i.tool_name, i.next_prompt_corrects,
       p.file_path, p.file_name, p.file_ext, p.file_path_parts,
       len(string_split(i.write_content, E'\n')) AS write_lines,
       i.agent_model, i.agent_subagent_type, i.agent_prompt, length(i.agent_prompt) AS agent_prompt_len,
       i.skill_name, i.slack_channel,
       [lower(w) FOR w IN string_split(i.linear_title, ' ') IF w <> ''] AS linear_title_words,
       b.* EXCLUDE (call_id),
       s.* EXCLUDE (call_id)
FROM tc_input i
LEFT JOIN tc_paths p USING (call_id)
LEFT JOIN bash_call_facts b USING (call_id)
LEFT JOIN sql_call_facts s USING (call_id);

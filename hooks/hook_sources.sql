-- Hook inputs for toolcall_facts.sql: the one PreToolUse event on stdin, parsed the way wave 1 parsed the corpus.
-- stdin and the Bash command each go into a ScalarFS variable, so nothing touches disk. stdin is read through
-- shellfs because Claude Code hands it over as a socket, which read_json_objects('/dev/stdin') cannot open.
LOAD scalarfs;
LOAD shellfs;
LOAD sitting_duck;
COPY (SELECT json AS event FROM read_json_objects('cat |')) TO 'variable:hook_event' (FORMAT json);
CREATE OR REPLACE VIEW tc_src AS
SELECT event ->> 'tool_use_id' AS call_id, event ->> 'session_id' AS session, now() AS ts,
       (event ->> 'agent_id') IS NOT NULL AS subagent, event ->> 'tool_name' AS tool_name,
       (event -> 'tool_input')::VARCHAR AS input, NULL::BOOLEAN AS next_prompt_corrects
FROM read_json('variable:hook_event', columns := {'event': 'JSON'});
-- wave 1's parse-bash chain reads `src` (the calls) and `n` (one row per bash AST node).
CREATE OR REPLACE VIEW src AS SELECT 'variable:hook_command.sh' AS ast_path, * FROM tc_src WHERE tool_name = 'Bash';
-- read_ast with peek := 'full' keeps whole node text (parse_ast_list cuts it at 80 characters, hiding SQL inside
-- duckdb -c). read_ast takes ScalarFS paths but skips a name without a parser extension, hence the .sh.
COPY (SELECT input::JSON ->> 'command' FROM src) TO 'variable:hook_command.sh' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', DELIMITER E'\x1f');
CREATE OR REPLACE VIEW n AS
SELECT s.call_id, f.node_id, f.parent_id, f.depth, f.sibling_index, f.type, f.name, f.children_count, f.descendant_count,
       f.start_line - 1 AS start_line, f.end_line - 1 AS end_line, f.peek
FROM read_ast('variable:hook_command.sh', 'bash', peek := 'full') AS f
JOIN src AS s ON s.ast_path = f.file_path;
.read /Users/aloksubbarao/duckdb-skills/hooks/parse_bash_view.sql

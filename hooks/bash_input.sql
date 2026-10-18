-- The parse-bash chain's inputs over the caller's tc_src: `src` (the Bash calls) and `n` (one row per bash AST node).
-- Read by hook_sources.sql (the hook) and skills/duckstack-review/gate.sql (the review queue, which has no Bash calls,
-- so src is empty and the command variable is an empty file).
CREATE OR REPLACE VIEW src AS SELECT 'variable:hook_command.sh' AS ast_path, * FROM tc_src WHERE tool_name = 'Bash';
-- read_ast with peek := 'full' keeps whole node text (parse_ast_list cuts it at 80 characters, hiding SQL inside
-- duckdb -c). read_ast takes ScalarFS paths but skips a name without a parser extension, hence the .sh.
COPY (SELECT input::JSON ->> 'command' FROM src) TO 'variable:hook_command.sh' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', DELIMITER E'\x1f');
CREATE OR REPLACE VIEW n AS
SELECT s.call_id, f.node_id, f.parent_id, f.depth, f.sibling_index, f.type, f.name, f.children_count, f.descendant_count,
       f.start_line - 1 AS start_line, f.end_line - 1 AS end_line, f.peek
FROM read_ast('variable:hook_command.sh', 'bash', peek := 'full') AS f
JOIN src AS s ON s.ast_path = f.file_path;

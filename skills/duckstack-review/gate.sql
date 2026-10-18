-- The review queue's rule check. Every .sql file a PR changes, and every ```sql block in a .md it changes, goes
-- through the hook's own facts and checks (toolcall_facts, hook_checks) as if an agent had just written it, so a
-- PR is held to the same rules as a tool call. The caller defines pr_files(pr_number, file_path, content) and runs
-- from a checkout root (the queue runs in ~/.duck/deploy, the checkout of main, so the rules are the merged ones).
LOAD scalarfs;
LOAD shellfs;
LOAD sitting_duck;
LOAD markdown;
CREATE OR REPLACE VIEW pr_sql AS
SELECT pr_number, file_path, content FROM pr_files WHERE ends_with(file_path, '.sql')
UNION ALL
SELECT pr_number, concat(file_path, '#sql', block.ordinality) AS file_path, block.code_block.code AS content
FROM pr_files CROSS JOIN UNNEST(md_extract_code_blocks(content)) WITH ORDINALITY AS block(code_block, ordinality)
-- duckstack-review's own BAD examples are deliberate.
WHERE ends_with(file_path, '.md') AND block.code_block.language = 'sql' AND NOT starts_with(file_path, 'skills/duckstack-review/');
CREATE OR REPLACE VIEW tc_src AS
SELECT concat_ws(':', pr_number, file_path) AS call_id, 'pr' AS session, now() AS ts, false AS subagent, 'Write' AS tool_name,
       json_object('file_path', file_path, 'content', content)::VARCHAR AS input, NULL::BOOLEAN AS next_prompt_corrects
FROM pr_sql;
-- No Bash calls come from a PR, but the parse-bash views read src and n, so both exist and are empty.
CREATE OR REPLACE VIEW src AS SELECT 'variable:hook_command.sh' AS ast_path, * FROM tc_src WHERE tool_name = 'Bash';
COPY (SELECT '' AS command) TO 'variable:hook_command.sh' (FORMAT csv, HEADER false, QUOTE '');
CREATE OR REPLACE VIEW n AS
SELECT s.call_id, f.node_id, f.parent_id, f.depth, f.sibling_index, f.type, f.name, f.children_count, f.descendant_count,
       f.start_line - 1 AS start_line, f.end_line - 1 AS end_line, f.peek
FROM read_ast('variable:hook_command.sh', 'bash', peek := 'full') AS f
JOIN src AS s ON s.ast_path = f.file_path;
.read hooks/parse_bash_view.sql
.read hooks/toolcall_facts.sql
.read hooks/hook_checks.sql
.read hooks/check_hits.sql
-- One row per PR, file and check that fired; action 'block' fails the PR, 'warn' is reported with it.
CREATE OR REPLACE VIEW pr_rule_hits AS
SELECT string_split(check_hits.call_id, ':')[1]::INTEGER AS pr_number, string_split(check_hits.call_id, ':')[2] AS file_path,
       hook_checks.check_id, hook_checks.action, hook_checks.message
FROM check_hits JOIN hook_checks USING (check_id)
WHERE hook_checks.action IN ('block', 'warn');

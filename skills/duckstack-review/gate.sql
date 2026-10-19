-- The review queue's rule check. Every .sql file a PR changes, and every ```sql block in a .md it changes, goes
-- through the hook's own facts and checks (toolcall_facts, hook_checks) as if an agent had just written it, so a
-- PR is held to the same rules as a tool call. The caller defines pr_versions(pr_number, file_path, side, content):
-- side 'head' is the file after the PR, 'base' the modified file as it is on main. It runs from a checkout root (the
-- queue runs in ~/.duck/deploy, the checkout of main, so the rules are the merged ones).
LOAD scalarfs;
LOAD shellfs;
LOAD sitting_duck;
LOAD markdown;
-- A ```sql block whose first line is '-- BAD' is a deliberate counter-example: its hits are reported as 'example'.
CREATE OR REPLACE VIEW pr_sql AS
SELECT pr_number, file_path, side, content, false AS bad_example FROM pr_versions WHERE ends_with(file_path, '.sql')
UNION ALL
-- named <file>#<n>.sql so toolcall_facts reads its extension as .sql
SELECT pr_number, concat(file_path, '#', block.ordinality, '.sql') AS file_path, side, block.code_block.code AS content,
       starts_with(ltrim(block.code_block.code), '-- BAD') AS bad_example
FROM pr_versions CROSS JOIN UNNEST(md_extract_code_blocks(content)) WITH ORDINALITY AS block(code_block, ordinality)
WHERE ends_with(file_path, '.md') AND block.code_block.language = 'sql';
CREATE OR REPLACE VIEW tc_src AS
SELECT pr_number, file_path, side, bad_example, concat_ws(':', side, pr_number, file_path) AS call_id, 'pr' AS session, now() AS ts,
       false AS subagent, 'Write' AS tool_name,
       json_object('file_path', file_path, 'content', content)::VARCHAR AS input, NULL::BOOLEAN AS next_prompt_corrects
FROM pr_sql;
-- The hook's own parse-bash inputs; no Bash calls come from a PR, so they are empty.
.read hooks/bash_input.sql
.read hooks/parse_bash_view.sql
.read hooks/toolcall_facts.sql
.read hooks/hook_checks.sql
.read hooks/check_hits.sql
-- One row per PR, file and check that fired on the PR's version; action 'block' fails the PR. 'warn', 'example', and
-- 'existing' (the same check already fires on main's copy of the file, so the PR did not add it) are reported with it.
-- shortcut: matched per file and check, so a second hit of a check the file already has passes; the Opus review
-- still sees the added lines. Match per line once check_hits carries line numbers.
CREATE OR REPLACE VIEW pr_rule_hits AS
WITH file_hits AS (
    SELECT DISTINCT tc_src.side, tc_src.pr_number, tc_src.file_path, tc_src.bad_example, check_hits.check_id
    FROM check_hits JOIN tc_src USING (call_id)
)
SELECT head.pr_number, head.file_path, head.check_id,
       CASE WHEN head.bad_example THEN 'example' WHEN base.check_id IS NOT NULL THEN 'existing' ELSE hook_checks.action END AS action,
       hook_checks.message
FROM file_hits AS head JOIN hook_checks USING (check_id)
LEFT JOIN file_hits AS base ON base.side = 'base' AND (base.pr_number, base.file_path, base.check_id) = (head.pr_number, head.file_path, head.check_id)
WHERE head.side = 'head' AND hook_checks.action IN ('block', 'warn');

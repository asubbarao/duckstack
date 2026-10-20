-- Runs the hook's own facts and checks over hook_cases.json, as if each case were a tool call, and prints
-- every case with the checks that fired on it. Run from the checkout root (tests/test_hook_checks.py does).
LOAD scalarfs;
LOAD shellfs;
LOAD sitting_duck;
CREATE OR REPLACE VIEW tc_src AS
SELECT case_id AS call_id, 'hook_cases' AS session, now() AS ts, false AS subagent, tool_name,
       input::JSON::VARCHAR AS input, NULL::BOOLEAN AS next_prompt_corrects
FROM read_json('tests/hook_cases.json');
.read hooks/bash_input.sql
.read hooks/parse_bash_view.sql
.read hooks/toolcall_facts.sql
.read hooks/hook_checks.sql
.read hooks/check_hits.sql
.mode json
SELECT cases.case_id, cases.fires, cases.quiet,
       list_sort(list_filter(array_agg(DISTINCT hits.check_id), check_id -> check_id IS NOT NULL)) AS fired,
       list_has_all(fired, cases.fires) AS fires_ok, NOT list_has_any(fired, cases.quiet) AS quiet_ok
FROM read_json('tests/hook_cases.json') AS cases
LEFT JOIN check_hits AS hits ON hits.call_id = cases.case_id
GROUP BY cases.case_id, cases.fires, cases.quiet ORDER BY cases.case_id;

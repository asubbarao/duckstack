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
.read /Users/aloksubbarao/.duck/deploy/hooks/bash_input.sql
.read /Users/aloksubbarao/.duck/deploy/hooks/parse_bash_view.sql

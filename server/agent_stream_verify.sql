-- Synthetic regression checks; run on the selected localhost:9495 service.
CREATE SCHEMA IF NOT EXISTS agent_stream_test;
CREATE OR REPLACE TABLE agent_stream_test.conversations AS
WITH examples AS (
 SELECT 1 AS line_number, 'user' AS message_type, 'user' AS message_role, 'hello' AS message_content, NULL::VARCHAR AS tool_name, NULL::VARCHAR AS tool_input, '2026-09-24T23:59:59-07:00' AS timestamp
 UNION ALL SELECT 2,'user','user','hello',NULL,NULL,'2026-09-24T23:59:59-07:00'
 UNION ALL SELECT 3,'assistant','assistant',NULL,'exec','{"x":1}','2026-09-24T00:04:59Z'
 UNION ALL SELECT 4,'assistant','assistant','Checking.','read','file.txt','2026-09-24T00:05:01Z'
 UNION ALL SELECT 5,'custom_tool_call','tool',NULL,NULL,NULL,NULL
 UNION ALL SELECT 6,'function_call_output','tool','done','exec',NULL,'2026-09-24T00:05:01Z'
 UNION ALL SELECT 7,'unknown',NULL,'strange',NULL,NULL,NULL
 UNION ALL SELECT 8,'assistant','assistant',repeat('A',1005)||repeat('B',1005),NULL,NULL,'2026-09-24T00:05:01Z'
 UNION ALL SELECT 1,'user','user','hello',NULL,NULL,'2026-09-24T23:59:59-07:00'
 UNION ALL SELECT 9,'function_call','tool','argument text',NULL,NULL,'2026-09-24T00:05:01Z'
 UNION ALL SELECT 10,'command_execution','tool','command output','command','["duckdb","-c","select 1"]','2026-09-24T00:05:01Z'
)
SELECT *, 'claude' AS system, 'fixture' AS session_id, '/fixture' AS project_path,
 'fixture.jsonl' AS file_name, NULL::VARCHAR AS uuid, NULL::VARCHAR AS tool_use_id, NULL::VARCHAR AS cwd, true AS is_agent
FROM examples;

WITH program AS (
 SELECT replace(substring(content, strpos(content, 'CREATE OR REPLACE TABLE agent.stream')),
                'agent.', 'agent_stream_test.') AS statement
 FROM read_text('/Users/aloksubbarao/duckdb-skills/server/agent_stream.sql')
), executed AS (
 SELECT statement, http_post_form('http://localhost:9495/sql', MAP{}, MAP{'sql': statement}) AS receipt
 FROM program
)
SELECT CASE WHEN receipt.status=200 THEN 'normalization executed'
 ELSE error(receipt.body) END AS execution
FROM executed;
SELECT CASE WHEN count(id)=13 AND count(DISTINCT id)=13
 AND count(id) FILTER (WHERE message_role='user')=3
 AND count(id) FILTER (WHERE line_number=3)=1
 AND count(id) FILTER (WHERE line_number=4)=2
 AND count(id) FILTER (WHERE line_number=5 AND message_role='tool_call' AND message_content IS NULL)=1
 AND count(id) FILTER (WHERE line_number=6 AND message_role='tool_result' AND message_content='done')=1
 AND count(id) FILTER (WHERE line_number=7 AND message_role='other' AND day IS NULL)=1
 AND count(id) FILTER (WHERE line_number=8 AND content_length=2010 AND length(message_content)=2010
     AND content_headtail=repeat('A',1000)||' … '||repeat('B',997))=1
 AND count(id) FILTER (WHERE line_number=9 AND message_role='tool_call' AND message_content='argument text')=1
 AND count(id) FILTER (WHERE line_number=10 AND message_role='tool_call' AND tool_data.input='["duckdb","-c","select 1"]')=1
 AND count(id) FILTER (WHERE line_number=10 AND message_role='tool_result' AND message_content='command output')=1
 AND count(id) FILTER (WHERE message_role='user' AND day=DATE '2026-09-25')=3
 AND count(id) FILTER (WHERE line_number=3 AND block=TIMESTAMPTZ '2026-09-24 00:00:00+00')=1
 THEN 'pass: retention, roles, arguments, nulls, UTC blocks and head/tail'
 ELSE error('stream normalization regression') END AS verification
FROM agent_stream_test.stream;
INSERT INTO agent_stream_test.conversations BY NAME
SELECT f.* FROM agent_stream_test.conversations f CROSS JOIN range(100)
WHERE f.line_number=2;
WITH program AS (
 SELECT replace(substring(content, strpos(content, 'CREATE OR REPLACE TABLE agent.stream')),
                'agent.', 'agent_stream_test.') AS statement
 FROM read_text('/Users/aloksubbarao/duckdb-skills/server/agent_stream.sql')
)
SELECT http_post_form('http://localhost:9495/sql', MAP{}, MAP{'sql': statement}) AS receipt FROM program;
SELECT CASE WHEN sum(message_count)=113 AND sum(len(samples))=20
 THEN 'pass: full counts and bounded previews' ELSE error('preview regression') END AS verification
FROM agent_stream_test.stream_day;
DROP SCHEMA agent_stream_test CASCADE;

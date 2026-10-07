-- agent_data query bank — execute one BANK section at a time on dev.
-- No SET variables, caches, or agent.stream. Each query spells out its source CTE.
-- Recent-run discovery uses Codex SQLite only to find paths; read_conversations supplies data.
-- The reader wrapper selects this Mac's already-running repaired reader at 19494.
-- With the repaired extension loaded locally, unwrap quack_query and use its inner SQL directly.
-- Case paths below are the five Luna low/high workers plus three native probes and this parent.
-- Change those path literals for another batch. Parent records are scoped to launch evidence;
-- child transcripts are complete. Launch reconstruction is a JS/nohup adapter, not universal.
-- parent_uuid is message ancestry; parent_session_id is a conversation link.
-- source + file_path are transcript keys. Claude siblings may share a session_id.
-- Arrays retain observed timestamps, flags, models and provenance; min/max and bool_or are extras.
-- usage_scope=response is deduplicated by response_id/record_id; never sum cumulative counters.
-- Usage-event span is not CPU time or wall-clock runtime. Item durations may overlap.
-- Historical inventory is recently UPDATED, capped at 128 files; LIMIT 7 only caps its preview.
-- Initial versus follow-up turns are separate. Different tasks do not estimate a causal effort effect.

-- BANK: recent_luna_runs
WITH files AS (
 SELECT id AS index_session_id,rollout_path AS file_path
 FROM sqlite_scan(getenv('HOME')||'/.codex/state_5.sqlite','threads')
 WHERE model='gpt-5.6-luna' AND updated_at>=epoch(current_timestamp-INTERVAL '3 days')
 ORDER BY updated_at DESC LIMIT 128
), programs AS (
 SELECT *,printf($outer$SELECT * FROM quack_query('quack:127.0.0.1:19494',
 $reader$%s$reader$,token:=getenv('QUACK_TOKEN')) LIMIT 7$outer$,
 printf($inner$WITH r AS (
 SELECT * FROM read_conversations(source:='codex',path:='%s')
), usage AS (
 SELECT * FROM r WHERE usage_scope='response'
 QUALIFY row_number() OVER(PARTITION BY source,file_path,coalesce(response_id,record_id)
 ORDER BY line_number)=1
), histories AS (
 SELECT source,session_id,file_path,array_agg(record_id ORDER BY line_number) AS record_ids,
 array_agg(try_cast(timestamp AS TIMESTAMPTZ) ORDER BY line_number) AS timestamps,
 array_agg(is_agent ORDER BY line_number) AS agent_flags,
 array_agg(model ORDER BY line_number) AS models,
 array_agg(reasoning_effort ORDER BY line_number) AS efforts,
 array_agg(parent_session_id ORDER BY line_number) AS parent_ids,
 bool_or(is_agent) AS any_is_agent
 FROM r GROUP BY source,session_id,file_path
), totals AS (
 SELECT source,session_id,file_path,
 array_agg(struct_pack(record_id:=record_id,response_id:=response_id,
 input_tokens:=input_tokens,cached_tokens:=cache_read_tokens,
 output_tokens:=output_tokens,reasoning_tokens:=reasoning_tokens)
 ORDER BY line_number) AS response_usage,
 sum(input_tokens) AS input_tokens,sum(cache_read_tokens) AS cached_tokens,
 sum(output_tokens) AS output_tokens,sum(reasoning_tokens) AS reasoning_tokens
 FROM usage GROUP BY source,session_id,file_path
)
SELECT histories.*,response_usage,input_tokens,cached_tokens,output_tokens,reasoning_tokens
FROM histories LEFT JOIN totals USING(source,session_id,file_path)$inner$,replace(file_path,chr(39),chr(39)||chr(39)))) AS sql FROM files
), receipts AS (
 SELECT *,http_post('http://localhost:9495/sql',map{'Content-Type':'application/json'},json_object('sql',sql))::JSON AS receipt
 FROM programs
), decoded AS (
 SELECT *,from_json(receipt->>'body','[{"source":"VARCHAR","session_id":"VARCHAR","file_path":"VARCHAR","record_ids":["VARCHAR"],"timestamps":["TIMESTAMPTZ"],"agent_flags":["BOOLEAN"],"models":["VARCHAR"],"efforts":["VARCHAR"],"parent_ids":["VARCHAR"],"any_is_agent":"BOOLEAN","response_usage":[{"record_id":"VARCHAR","response_id":"VARCHAR","input_tokens":"BIGINT","cached_tokens":"BIGINT","output_tokens":"BIGINT","reasoning_tokens":"BIGINT"}],"input_tokens":"BIGINT","cached_tokens":"BIGINT","output_tokens":"BIGINT","reasoning_tokens":"BIGINT"}]') AS rows
 FROM receipts WHERE receipt->>'status'='200'
), sessions AS (
 SELECT index_session_id,sql,receipt,row.* FROM decoded CROSS JOIN UNNEST(rows) AS u(row)
)
SELECT source,session_id,file_path,len(record_ids) AS records,
 list_min(timestamps) AS first_ts,list_max(timestamps) AS last_ts,
 list_distinct(models) AS models_seen,list_distinct(efforts) AS efforts_seen,
 list_distinct(parent_ids) AS parents_seen,agent_flags,any_is_agent,
 input_tokens,cached_tokens,output_tokens,reasoning_tokens
FROM sessions ORDER BY last_ts DESC LIMIT 7;

-- BANK: case_inventory
WITH source_rows AS (
 SELECT * FROM quack_query('quack:127.0.0.1:19494',$reader$
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-36-01a0f351-70ea-7702-ae0c-6004665c20aa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-42-01a0f351-8b53-73a2-a637-fe1957632d35.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-52-01a0f351-b204-7921-a20c-e883745e4d46.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-29-01a0f8c9-29ec-74e2-8ffc-a834f888eb22.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2ad3-7c71-bff5-d6fc12fdef3f.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2bd0-75c1-925d-5e9247e137fa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2cd0-73a0-8ff9-4131142eec92.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2dce-7541-93f4-2b1b59252337.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
WHERE tool_use_id IN (
 SELECT tool_use_id FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
 WHERE contains(tool_input,'codex exec') AND contains(tool_input,'nohup')
 AND contains(tool_input,'const body=')
)
$reader$,token:=getenv('QUACK_TOKEN'))
), r AS (
 SELECT *,try_cast(timestamp AS TIMESTAMPTZ) AS ts FROM source_rows
), sessions AS (
 SELECT source,session_id,file_path,
 array_agg(ts ORDER BY line_number) AS timestamps,
 array_agg(cwd ORDER BY line_number) AS directories,
 array_agg(parent_session_id ORDER BY line_number) AS parent_ids,
 array_agg(thread_source ORDER BY line_number) AS thread_sources,
 array_agg(is_agent ORDER BY line_number) AS agent_flags,
 array_agg(model ORDER BY line_number) AS models,
 array_agg(reasoning_effort ORDER BY line_number) AS efforts,
 array_agg(record_id ORDER BY line_number) AS record_ids,
 bool_or(is_agent) AS any_is_agent
 FROM r GROUP BY source,session_id,file_path
), s AS (
 SELECT *,list_min(timestamps) AS first_ts,list_max(timestamps) AS last_ts,
 list_distinct(directories) AS distinct_directories,
 list_distinct(parent_ids) AS distinct_parents,
 list_distinct(thread_sources) AS distinct_thread_sources,
 list_distinct(models) AS distinct_models,
 list_distinct(efforts) AS distinct_efforts
 FROM sessions
)
SELECT source,session_id,file_path,first_ts,last_ts,distinct_models,distinct_efforts,
 distinct_parents,distinct_thread_sources,agent_flags,any_is_agent,len(record_ids) AS records
FROM s ORDER BY first_ts LIMIT 20;

-- BANK: parent_child_edges
WITH source_rows AS (
 SELECT * FROM quack_query('quack:127.0.0.1:19494',$reader$
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-36-01a0f351-70ea-7702-ae0c-6004665c20aa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-42-01a0f351-8b53-73a2-a637-fe1957632d35.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-52-01a0f351-b204-7921-a20c-e883745e4d46.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-29-01a0f8c9-29ec-74e2-8ffc-a834f888eb22.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2ad3-7c71-bff5-d6fc12fdef3f.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2bd0-75c1-925d-5e9247e137fa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2cd0-73a0-8ff9-4131142eec92.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2dce-7541-93f4-2b1b59252337.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
WHERE tool_use_id IN (
 SELECT tool_use_id FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
 WHERE contains(tool_input,'codex exec') AND contains(tool_input,'nohup')
 AND contains(tool_input,'const body=')
)
$reader$,token:=getenv('QUACK_TOKEN'))
), r AS (
 SELECT *,try_cast(timestamp AS TIMESTAMPTZ) AS ts FROM source_rows
), sessions AS (
 SELECT source,session_id,file_path,
 array_agg(ts ORDER BY line_number) AS timestamps,
 array_agg(cwd ORDER BY line_number) AS directories,
 array_agg(parent_session_id ORDER BY line_number) AS parent_ids,
 array_agg(thread_source ORDER BY line_number) AS thread_sources,
 array_agg(is_agent ORDER BY line_number) AS agent_flags,
 array_agg(model ORDER BY line_number) AS models,
 array_agg(reasoning_effort ORDER BY line_number) AS efforts,
 array_agg(record_id ORDER BY line_number) AS record_ids,
 bool_or(is_agent) AS any_is_agent
 FROM r GROUP BY source,session_id,file_path
), s AS (
 SELECT *,list_min(timestamps) AS first_ts,list_max(timestamps) AS last_ts,
 list_distinct(directories) AS distinct_directories,
 list_distinct(parent_ids) AS distinct_parents,
 list_distinct(thread_sources) AS distinct_thread_sources,
 list_distinct(models) AS distinct_models,
 list_distinct(efforts) AS distinct_efforts
 FROM sessions
), launches AS (
 SELECT * FROM r WHERE contains(tool_input,'codex exec')
 AND contains(tool_input,'nohup') AND contains(tool_input,'const body=')
), results AS (
 SELECT * FROM r WHERE message_type='custom_tool_call_output'
), reconstructed AS (
 SELECT child.source AS child_source,child.session_id AS child_session_id,
 child.file_path AS child_file,launch.source AS parent_source,
 launch.session_id AS parent_session_id,launch.file_path AS parent_file,
 'launch_call_and_result' AS evidence_kind,launch.record_id AS evidence_record,
 result.record_id AS result_record,launch.ts AS evidence_ts
 FROM launches AS launch JOIN results AS result
 ON launch.source=result.source AND launch.file_path=result.file_path
 AND launch.tool_use_id=result.tool_use_id
 JOIN s AS child ON len(child.distinct_directories)=1
 AND contains(result.raw_event,child.distinct_directories[1])
 AND child.first_ts BETWEEN launch.ts AND launch.ts+INTERVAL '2 minutes'
 WHERE child.session_id IS DISTINCT FROM launch.session_id
 AND list_contains(child.distinct_thread_sources,'exec')
), native AS (
 SELECT child.source AS child_source,child.session_id AS child_session_id,
 child.file_path AS child_file,child.source AS parent_source,
 p.parent_session_id,parent.file_path AS parent_file,
 'native_parent_session_id' AS evidence_kind,NULL::VARCHAR AS evidence_record,
 NULL::VARCHAR AS result_record,child.first_ts AS evidence_ts
 FROM s AS child CROSS JOIN UNNEST(child.distinct_parents) AS p(parent_session_id)
 LEFT JOIN s AS parent ON child.source=parent.source
 AND p.parent_session_id=parent.session_id
), edges AS (
 SELECT * FROM native UNION ALL BY NAME SELECT * FROM reconstructed
)
SELECT * FROM edges ORDER BY evidence_ts,child_session_id LIMIT 20;

-- BANK: fanout_by_parent
WITH source_rows AS (
 SELECT * FROM quack_query('quack:127.0.0.1:19494',$reader$
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-36-01a0f351-70ea-7702-ae0c-6004665c20aa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-42-01a0f351-8b53-73a2-a637-fe1957632d35.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-52-01a0f351-b204-7921-a20c-e883745e4d46.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-29-01a0f8c9-29ec-74e2-8ffc-a834f888eb22.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2ad3-7c71-bff5-d6fc12fdef3f.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2bd0-75c1-925d-5e9247e137fa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2cd0-73a0-8ff9-4131142eec92.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2dce-7541-93f4-2b1b59252337.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
WHERE tool_use_id IN (
 SELECT tool_use_id FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
 WHERE contains(tool_input,'codex exec') AND contains(tool_input,'nohup')
 AND contains(tool_input,'const body=')
)
$reader$,token:=getenv('QUACK_TOKEN'))
), r AS (
 SELECT *,try_cast(timestamp AS TIMESTAMPTZ) AS ts FROM source_rows
), sessions AS (
 SELECT source,session_id,file_path,
 array_agg(ts ORDER BY line_number) AS timestamps,
 array_agg(cwd ORDER BY line_number) AS directories,
 array_agg(parent_session_id ORDER BY line_number) AS parent_ids,
 array_agg(thread_source ORDER BY line_number) AS thread_sources,
 array_agg(is_agent ORDER BY line_number) AS agent_flags,
 array_agg(model ORDER BY line_number) AS models,
 array_agg(reasoning_effort ORDER BY line_number) AS efforts,
 array_agg(record_id ORDER BY line_number) AS record_ids,
 bool_or(is_agent) AS any_is_agent
 FROM r GROUP BY source,session_id,file_path
), s AS (
 SELECT *,list_min(timestamps) AS first_ts,list_max(timestamps) AS last_ts,
 list_distinct(directories) AS distinct_directories,
 list_distinct(parent_ids) AS distinct_parents,
 list_distinct(thread_sources) AS distinct_thread_sources,
 list_distinct(models) AS distinct_models,
 list_distinct(efforts) AS distinct_efforts
 FROM sessions
), launches AS (
 SELECT * FROM r WHERE contains(tool_input,'codex exec')
 AND contains(tool_input,'nohup') AND contains(tool_input,'const body=')
), results AS (
 SELECT * FROM r WHERE message_type='custom_tool_call_output'
), reconstructed AS (
 SELECT child.source AS child_source,child.session_id AS child_session_id,
 child.file_path AS child_file,launch.source AS parent_source,
 launch.session_id AS parent_session_id,launch.file_path AS parent_file,
 'launch_call_and_result' AS evidence_kind,launch.record_id AS evidence_record,
 result.record_id AS result_record,launch.ts AS evidence_ts
 FROM launches AS launch JOIN results AS result
 ON launch.source=result.source AND launch.file_path=result.file_path
 AND launch.tool_use_id=result.tool_use_id
 JOIN s AS child ON len(child.distinct_directories)=1
 AND contains(result.raw_event,child.distinct_directories[1])
 AND child.first_ts BETWEEN launch.ts AND launch.ts+INTERVAL '2 minutes'
 WHERE child.session_id IS DISTINCT FROM launch.session_id
 AND list_contains(child.distinct_thread_sources,'exec')
), native AS (
 SELECT child.source AS child_source,child.session_id AS child_session_id,
 child.file_path AS child_file,child.source AS parent_source,
 p.parent_session_id,parent.file_path AS parent_file,
 'native_parent_session_id' AS evidence_kind,NULL::VARCHAR AS evidence_record,
 NULL::VARCHAR AS result_record,child.first_ts AS evidence_ts
 FROM s AS child CROSS JOIN UNNEST(child.distinct_parents) AS p(parent_session_id)
 LEFT JOIN s AS parent ON child.source=parent.source
 AND p.parent_session_id=parent.session_id
), edges AS (
 SELECT * FROM native UNION ALL BY NAME SELECT * FROM reconstructed
)
SELECT parent_source,parent_session_id,array_agg(struct_pack(child_id:=child_session_id,
 child_file:=child_file,evidence:=evidence_kind,launch_record:=evidence_record)
 ORDER BY child_session_id) AS children FROM edges
GROUP BY parent_source,parent_session_id LIMIT 7;

-- BANK: ambiguous_edges
WITH source_rows AS (
 SELECT * FROM quack_query('quack:127.0.0.1:19494',$reader$
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-36-01a0f351-70ea-7702-ae0c-6004665c20aa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-42-01a0f351-8b53-73a2-a637-fe1957632d35.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-52-01a0f351-b204-7921-a20c-e883745e4d46.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-29-01a0f8c9-29ec-74e2-8ffc-a834f888eb22.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2ad3-7c71-bff5-d6fc12fdef3f.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2bd0-75c1-925d-5e9247e137fa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2cd0-73a0-8ff9-4131142eec92.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2dce-7541-93f4-2b1b59252337.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
WHERE tool_use_id IN (
 SELECT tool_use_id FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
 WHERE contains(tool_input,'codex exec') AND contains(tool_input,'nohup')
 AND contains(tool_input,'const body=')
)
$reader$,token:=getenv('QUACK_TOKEN'))
), r AS (
 SELECT *,try_cast(timestamp AS TIMESTAMPTZ) AS ts FROM source_rows
), sessions AS (
 SELECT source,session_id,file_path,
 array_agg(ts ORDER BY line_number) AS timestamps,
 array_agg(cwd ORDER BY line_number) AS directories,
 array_agg(parent_session_id ORDER BY line_number) AS parent_ids,
 array_agg(thread_source ORDER BY line_number) AS thread_sources,
 array_agg(is_agent ORDER BY line_number) AS agent_flags,
 array_agg(model ORDER BY line_number) AS models,
 array_agg(reasoning_effort ORDER BY line_number) AS efforts,
 array_agg(record_id ORDER BY line_number) AS record_ids,
 bool_or(is_agent) AS any_is_agent
 FROM r GROUP BY source,session_id,file_path
), s AS (
 SELECT *,list_min(timestamps) AS first_ts,list_max(timestamps) AS last_ts,
 list_distinct(directories) AS distinct_directories,
 list_distinct(parent_ids) AS distinct_parents,
 list_distinct(thread_sources) AS distinct_thread_sources,
 list_distinct(models) AS distinct_models,
 list_distinct(efforts) AS distinct_efforts
 FROM sessions
), launches AS (
 SELECT * FROM r WHERE contains(tool_input,'codex exec')
 AND contains(tool_input,'nohup') AND contains(tool_input,'const body=')
), results AS (
 SELECT * FROM r WHERE message_type='custom_tool_call_output'
), reconstructed AS (
 SELECT child.source AS child_source,child.session_id AS child_session_id,
 child.file_path AS child_file,launch.source AS parent_source,
 launch.session_id AS parent_session_id,launch.file_path AS parent_file,
 'launch_call_and_result' AS evidence_kind,launch.record_id AS evidence_record,
 result.record_id AS result_record,launch.ts AS evidence_ts
 FROM launches AS launch JOIN results AS result
 ON launch.source=result.source AND launch.file_path=result.file_path
 AND launch.tool_use_id=result.tool_use_id
 JOIN s AS child ON len(child.distinct_directories)=1
 AND contains(result.raw_event,child.distinct_directories[1])
 AND child.first_ts BETWEEN launch.ts AND launch.ts+INTERVAL '2 minutes'
 WHERE child.session_id IS DISTINCT FROM launch.session_id
 AND list_contains(child.distinct_thread_sources,'exec')
), native AS (
 SELECT child.source AS child_source,child.session_id AS child_session_id,
 child.file_path AS child_file,child.source AS parent_source,
 p.parent_session_id,parent.file_path AS parent_file,
 'native_parent_session_id' AS evidence_kind,NULL::VARCHAR AS evidence_record,
 NULL::VARCHAR AS result_record,child.first_ts AS evidence_ts
 FROM s AS child CROSS JOIN UNNEST(child.distinct_parents) AS p(parent_session_id)
 LEFT JOIN s AS parent ON child.source=parent.source
 AND p.parent_session_id=parent.session_id
), edges AS (
 SELECT * FROM native UNION ALL BY NAME SELECT * FROM reconstructed
)
SELECT child_source,child_session_id,child_file,array_agg(struct_pack(
 parent:=parent_session_id,evidence:=evidence_kind,record_id:=evidence_record)) AS candidates
FROM edges GROUP BY child_source,child_session_id,child_file
HAVING len(list_distinct(array_agg(parent_session_id)))>1 LIMIT 20;

-- BANK: unlinked_cli_sessions
WITH source_rows AS (
 SELECT * FROM quack_query('quack:127.0.0.1:19494',$reader$
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-36-01a0f351-70ea-7702-ae0c-6004665c20aa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-42-01a0f351-8b53-73a2-a637-fe1957632d35.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-52-01a0f351-b204-7921-a20c-e883745e4d46.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-29-01a0f8c9-29ec-74e2-8ffc-a834f888eb22.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2ad3-7c71-bff5-d6fc12fdef3f.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2bd0-75c1-925d-5e9247e137fa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2cd0-73a0-8ff9-4131142eec92.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2dce-7541-93f4-2b1b59252337.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
WHERE tool_use_id IN (
 SELECT tool_use_id FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
 WHERE contains(tool_input,'codex exec') AND contains(tool_input,'nohup')
 AND contains(tool_input,'const body=')
)
$reader$,token:=getenv('QUACK_TOKEN'))
), r AS (
 SELECT *,try_cast(timestamp AS TIMESTAMPTZ) AS ts FROM source_rows
), sessions AS (
 SELECT source,session_id,file_path,
 array_agg(ts ORDER BY line_number) AS timestamps,
 array_agg(cwd ORDER BY line_number) AS directories,
 array_agg(parent_session_id ORDER BY line_number) AS parent_ids,
 array_agg(thread_source ORDER BY line_number) AS thread_sources,
 array_agg(is_agent ORDER BY line_number) AS agent_flags,
 array_agg(model ORDER BY line_number) AS models,
 array_agg(reasoning_effort ORDER BY line_number) AS efforts,
 array_agg(record_id ORDER BY line_number) AS record_ids,
 bool_or(is_agent) AS any_is_agent
 FROM r GROUP BY source,session_id,file_path
), s AS (
 SELECT *,list_min(timestamps) AS first_ts,list_max(timestamps) AS last_ts,
 list_distinct(directories) AS distinct_directories,
 list_distinct(parent_ids) AS distinct_parents,
 list_distinct(thread_sources) AS distinct_thread_sources,
 list_distinct(models) AS distinct_models,
 list_distinct(efforts) AS distinct_efforts
 FROM sessions
), launches AS (
 SELECT * FROM r WHERE contains(tool_input,'codex exec')
 AND contains(tool_input,'nohup') AND contains(tool_input,'const body=')
), results AS (
 SELECT * FROM r WHERE message_type='custom_tool_call_output'
), reconstructed AS (
 SELECT child.source AS child_source,child.session_id AS child_session_id,
 child.file_path AS child_file,launch.source AS parent_source,
 launch.session_id AS parent_session_id,launch.file_path AS parent_file,
 'launch_call_and_result' AS evidence_kind,launch.record_id AS evidence_record,
 result.record_id AS result_record,launch.ts AS evidence_ts
 FROM launches AS launch JOIN results AS result
 ON launch.source=result.source AND launch.file_path=result.file_path
 AND launch.tool_use_id=result.tool_use_id
 JOIN s AS child ON len(child.distinct_directories)=1
 AND contains(result.raw_event,child.distinct_directories[1])
 AND child.first_ts BETWEEN launch.ts AND launch.ts+INTERVAL '2 minutes'
 WHERE child.session_id IS DISTINCT FROM launch.session_id
 AND list_contains(child.distinct_thread_sources,'exec')
), native AS (
 SELECT child.source AS child_source,child.session_id AS child_session_id,
 child.file_path AS child_file,child.source AS parent_source,
 p.parent_session_id,parent.file_path AS parent_file,
 'native_parent_session_id' AS evidence_kind,NULL::VARCHAR AS evidence_record,
 NULL::VARCHAR AS result_record,child.first_ts AS evidence_ts
 FROM s AS child CROSS JOIN UNNEST(child.distinct_parents) AS p(parent_session_id)
 LEFT JOIN s AS parent ON child.source=parent.source
 AND p.parent_session_id=parent.session_id
), edges AS (
 SELECT * FROM native UNION ALL BY NAME SELECT * FROM reconstructed
)
SELECT s.source,s.session_id,s.file_path,s.distinct_efforts,s.distinct_thread_sources
FROM s ANTI JOIN edges ON s.source=edges.child_source AND s.file_path=edges.child_file
WHERE list_contains(s.distinct_thread_sources,'exec') LIMIT 20;

-- BANK: message_uuid_links
WITH source_rows AS (
 SELECT * FROM quack_query('quack:127.0.0.1:19494',$reader$
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-36-01a0f351-70ea-7702-ae0c-6004665c20aa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-42-01a0f351-8b53-73a2-a637-fe1957632d35.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-52-01a0f351-b204-7921-a20c-e883745e4d46.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-29-01a0f8c9-29ec-74e2-8ffc-a834f888eb22.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2ad3-7c71-bff5-d6fc12fdef3f.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2bd0-75c1-925d-5e9247e137fa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2cd0-73a0-8ff9-4131142eec92.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2dce-7541-93f4-2b1b59252337.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
WHERE tool_use_id IN (
 SELECT tool_use_id FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
 WHERE contains(tool_input,'codex exec') AND contains(tool_input,'nohup')
 AND contains(tool_input,'const body=')
)
$reader$,token:=getenv('QUACK_TOKEN'))
), r AS (
 SELECT *,try_cast(timestamp AS TIMESTAMPTZ) AS ts FROM source_rows
)
SELECT child.source,child.file_path,child.session_id,child.record_id AS child_record,
 child.uuid AS child_uuid,child.parent_uuid,parent.record_id AS parent_record,
 parent.file_path AS parent_file,child.ts,parent.ts AS parent_ts
FROM r AS child LEFT JOIN r AS parent ON child.source=parent.source
 AND child.session_id=parent.session_id AND child.parent_uuid=parent.uuid
WHERE child.parent_uuid IS NOT NULL ORDER BY child.ts LIMIT 20;

-- BANK: tool_calls_and_results
WITH source_rows AS (
 SELECT * FROM quack_query('quack:127.0.0.1:19494',$reader$
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-36-01a0f351-70ea-7702-ae0c-6004665c20aa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-42-01a0f351-8b53-73a2-a637-fe1957632d35.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-52-01a0f351-b204-7921-a20c-e883745e4d46.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-29-01a0f8c9-29ec-74e2-8ffc-a834f888eb22.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2ad3-7c71-bff5-d6fc12fdef3f.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2bd0-75c1-925d-5e9247e137fa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2cd0-73a0-8ff9-4131142eec92.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2dce-7541-93f4-2b1b59252337.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
WHERE tool_use_id IN (
 SELECT tool_use_id FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
 WHERE contains(tool_input,'codex exec') AND contains(tool_input,'nohup')
 AND contains(tool_input,'const body=')
)
$reader$,token:=getenv('QUACK_TOKEN'))
), r AS (
 SELECT *,try_cast(timestamp AS TIMESTAMPTZ) AS ts FROM source_rows
), calls AS (
 SELECT * FROM r WHERE tool_name IS NOT NULL AND tool_use_id IS NOT NULL
), outputs AS (
 SELECT * FROM r WHERE message_type IN ('custom_tool_call_output','function_call_output','tool_result')
)
SELECT calls.source,calls.session_id,calls.file_path,calls.record_id AS call_record,
 outputs.record_id AS result_record,calls.tool_use_id,calls.tool_name,calls.ts AS called_at,
 outputs.ts AS returned_at,outputs.ts-calls.ts AS event_gap,
 left(calls.tool_input,180) AS input_preview,left(outputs.raw_event,180) AS output_preview
FROM calls LEFT JOIN outputs ON calls.source=outputs.source
 AND calls.file_path=outputs.file_path AND calls.tool_use_id=outputs.tool_use_id
ORDER BY called_at DESC LIMIT 20;

-- BANK: luna_usage_per_turn
WITH source_rows AS (
 SELECT * FROM quack_query('quack:127.0.0.1:19494',$reader$
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-36-01a0f351-70ea-7702-ae0c-6004665c20aa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-42-01a0f351-8b53-73a2-a637-fe1957632d35.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-52-01a0f351-b204-7921-a20c-e883745e4d46.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-29-01a0f8c9-29ec-74e2-8ffc-a834f888eb22.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2ad3-7c71-bff5-d6fc12fdef3f.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2bd0-75c1-925d-5e9247e137fa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2cd0-73a0-8ff9-4131142eec92.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2dce-7541-93f4-2b1b59252337.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
WHERE tool_use_id IN (
 SELECT tool_use_id FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
 WHERE contains(tool_input,'codex exec') AND contains(tool_input,'nohup')
 AND contains(tool_input,'const body=')
)
$reader$,token:=getenv('QUACK_TOKEN'))
), r AS (
 SELECT *,try_cast(timestamp AS TIMESTAMPTZ) AS ts FROM source_rows
), usage AS (
 SELECT * FROM r WHERE usage_scope='response'
 QUALIFY row_number() OVER (
 PARTITION BY source,file_path,coalesce(response_id,record_id)
 ORDER BY line_number)=1
), turns AS (
 SELECT source,session_id,file_path,turn_id,model,reasoning_effort,
 array_agg(ts ORDER BY line_number) AS timestamps,
 array_agg(struct_pack(record_id:=record_id,response_id:=response_id,
 input_tokens:=input_tokens,cached_tokens:=cache_read_tokens,
 output_tokens:=output_tokens,reasoning_tokens:=reasoning_tokens)
 ORDER BY line_number) AS response_usage,
 sum(input_tokens) AS input_tokens,sum(cache_read_tokens) AS cached_tokens,
 sum(output_tokens) AS output_tokens,sum(reasoning_tokens) AS reasoning_tokens
 FROM usage GROUP BY source,session_id,file_path,turn_id,model,reasoning_effort
)
SELECT *,list_min(timestamps) AS first_usage_ts,list_max(timestamps) AS last_usage_ts,
 list_max(timestamps)-list_min(timestamps) AS usage_event_span
FROM turns WHERE model='gpt-5.6-luna' ORDER BY first_usage_ts LIMIT 20;

-- BANK: effort_observations
WITH source_rows AS (
 SELECT * FROM quack_query('quack:127.0.0.1:19494',$reader$
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-36-01a0f351-70ea-7702-ae0c-6004665c20aa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-42-01a0f351-8b53-73a2-a637-fe1957632d35.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-52-01a0f351-b204-7921-a20c-e883745e4d46.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-29-01a0f8c9-29ec-74e2-8ffc-a834f888eb22.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2ad3-7c71-bff5-d6fc12fdef3f.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2bd0-75c1-925d-5e9247e137fa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2cd0-73a0-8ff9-4131142eec92.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2dce-7541-93f4-2b1b59252337.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
WHERE tool_use_id IN (
 SELECT tool_use_id FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
 WHERE contains(tool_input,'codex exec') AND contains(tool_input,'nohup')
 AND contains(tool_input,'const body=')
)
$reader$,token:=getenv('QUACK_TOKEN'))
), r AS (
 SELECT *,try_cast(timestamp AS TIMESTAMPTZ) AS ts FROM source_rows
), usage AS (
 SELECT * FROM r WHERE usage_scope='response'
 QUALIFY row_number() OVER (
 PARTITION BY source,file_path,coalesce(response_id,record_id)
 ORDER BY line_number)=1
), turns AS (
 SELECT source,session_id,file_path,turn_id,model,reasoning_effort,
 array_agg(ts ORDER BY line_number) AS timestamps,
 array_agg(struct_pack(record_id:=record_id,response_id:=response_id,
 input_tokens:=input_tokens,cached_tokens:=cache_read_tokens,
 output_tokens:=output_tokens,reasoning_tokens:=reasoning_tokens)
 ORDER BY line_number) AS response_usage,
 sum(input_tokens) AS input_tokens,sum(cache_read_tokens) AS cached_tokens,
 sum(output_tokens) AS output_tokens,sum(reasoning_tokens) AS reasoning_tokens
 FROM usage GROUP BY source,session_id,file_path,turn_id,model,reasoning_effort
)
SELECT reasoning_effort,array_agg(struct_pack(session_id:=session_id,turn_id:=turn_id,
 input_tokens:=input_tokens,cached_tokens:=cached_tokens,output_tokens:=output_tokens,
 reasoning_tokens:=reasoning_tokens,timestamps:=timestamps) ORDER BY session_id,turn_id) AS runs,
 sum(input_tokens) AS input_tokens,sum(cached_tokens) AS cached_tokens,
 sum(output_tokens) AS output_tokens,sum(reasoning_tokens) AS reasoning_tokens
FROM turns WHERE model='gpt-5.6-luna' GROUP BY reasoning_effort LIMIT 7;

-- BANK: event_timing
WITH source_rows AS (
 SELECT * FROM quack_query('quack:127.0.0.1:19494',$reader$
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-36-01a0f351-70ea-7702-ae0c-6004665c20aa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-42-01a0f351-8b53-73a2-a637-fe1957632d35.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-52-01a0f351-b204-7921-a20c-e883745e4d46.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-29-01a0f8c9-29ec-74e2-8ffc-a834f888eb22.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2ad3-7c71-bff5-d6fc12fdef3f.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2bd0-75c1-925d-5e9247e137fa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2cd0-73a0-8ff9-4131142eec92.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2dce-7541-93f4-2b1b59252337.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
WHERE tool_use_id IN (
 SELECT tool_use_id FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
 WHERE contains(tool_input,'codex exec') AND contains(tool_input,'nohup')
 AND contains(tool_input,'const body=')
)
$reader$,token:=getenv('QUACK_TOKEN'))
), r AS (
 SELECT *,try_cast(timestamp AS TIMESTAMPTZ) AS ts FROM source_rows
), timed AS (
 SELECT *,try_cast(json_extract_string(raw_event,'$.payload.started_at_ms') AS BIGINT) AS started_ms,
 try_cast(json_extract_string(raw_event,'$.payload.completed_at_ms') AS BIGINT) AS completed_ms,
 json_extract_string(raw_event,'$.payload.item.type') AS item_type FROM r
)
SELECT source,session_id,file_path,turn_id,item_type,
 array_agg(struct_pack(record_id:=record_id,started_ms:=started_ms,completed_ms:=completed_ms)
 ORDER BY line_number) AS intervals,sum(completed_ms-started_ms)/1000 AS summed_item_seconds
FROM timed WHERE started_ms IS NOT NULL GROUP BY source,session_id,file_path,turn_id,item_type
ORDER BY session_id,turn_id,item_type LIMIT 100;

-- BANK: diagnostics
WITH source_rows AS (
 SELECT * FROM quack_query('quack:127.0.0.1:19494',$reader$
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-36-01a0f351-70ea-7702-ae0c-6004665c20aa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-42-01a0f351-8b53-73a2-a637-fe1957632d35.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/30/rollout-2026-09-30T10-16-52-01a0f351-b204-7921-a20c-e883745e4d46.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-29-01a0f8c9-29ec-74e2-8ffc-a834f888eb22.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2ad3-7c71-bff5-d6fc12fdef3f.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2bd0-75c1-925d-5e9247e137fa.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2cd0-73a0-8ff9-4131142eec92.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/10/01/rollout-2026-10-01T11-45-30-01a0f8c9-2dce-7541-93f4-2b1b59252337.jsonl')
UNION ALL BY NAME
SELECT * EXCLUDE(metadata) FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
WHERE tool_use_id IN (
 SELECT tool_use_id FROM read_conversations(source:='codex',path:='/Users/aloksubbarao/.codex/sessions/2026/09/29/rollout-2026-09-29T15-02-07-01a0ef30-7be5-7d62-8e42-0da4fdb257b5.jsonl')
 WHERE contains(tool_input,'codex exec') AND contains(tool_input,'nohup')
 AND contains(tool_input,'const body=')
)
$reader$,token:=getenv('QUACK_TOKEN'))
), r AS (
 SELECT *,try_cast(timestamp AS TIMESTAMPTZ) AS ts FROM source_rows
)
SELECT source,session_id,file_path,array_agg(struct_pack(record_id:=record_id,
 line_number:=line_number,error:=parse_error) ORDER BY line_number) AS errors
FROM r WHERE parse_error IS NOT NULL GROUP BY source,session_id,file_path LIMIT 20;

-- Bounded provider roots: the native reader accepts roots, not individual JSONL paths.
-- SQL owns source discovery, normalization and writes. ShellFS only creates symlinks
-- and submits the generated JSON SQL bodies sequentially to the existing dev API.
CREATE SCHEMA IF NOT EXISTS agent;
CREATE TABLE IF NOT EXISTS agent.stream_ingest_batches (
 run_id UUID, source VARCHAR, batch BIGINT, source_rows BIGINT, normalized_rows BIGINT,
 completed_at TIMESTAMPTZ);
UPDATE agent.stream_refresh SET status='failed', error='interrupted before completion'
 WHERE status='running';
CREATE OR REPLACE TEMP TABLE stream_run AS
 SELECT uuid() AS run_id,getenv('QUACK_INSTANCE_ID') AS instance_id,
 now() AS started_at,now() AS source_coverage_at;
INSERT INTO agent.stream_refresh BY NAME
 SELECT *, 'running' AS status FROM stream_run;
SET VARIABLE stream_source_cutoff = (SELECT max(source_coverage_at) - INTERVAL '5 seconds'
 FROM agent.stream_refresh WHERE status='success'
 AND EXISTS (SELECT table_name FROM duckdb_tables() WHERE schema_name='agent' AND table_name='stream'));
SET VARIABLE stream_work_root = (SELECT '/Users/aloksubbarao/.duck/stream_ingest/' || run_id FROM stream_run);
SET VARIABLE stream_mkdir = 'mkdir -p "' || getvariable('stream_work_root') || '" |';
FROM read_text(getvariable('stream_mkdir'));
CREATE OR REPLACE TEMP TABLE stream_pending_files AS
WITH files AS (
 SELECT file AS path, CASE WHEN starts_with(file,'/Users/aloksubbarao/.claude/') THEN 'claude' ELSE 'codex' END AS source,
 file_size(file) AS bytes,file_last_modified(file) AT TIME ZONE 'UTC' AS modified_at
 FROM glob(['/Users/aloksubbarao/.claude/projects/**/*.jsonl','/Users/aloksubbarao/.codex/sessions/**/*.jsonl'])
), pending AS (
 SELECT * FROM files WHERE CASE WHEN getvariable('stream_source_cutoff') IS NULL THEN true
 ELSE modified_at >= getvariable('stream_source_cutoff')::TIMESTAMPTZ END
), batches AS (
 SELECT *, floor((sum(bytes) OVER (PARTITION BY source ORDER BY path)-bytes)/134217728)::BIGINT AS batch
 FROM pending
)
SELECT *, getvariable('stream_work_root') || '/inputs/' || source || '/' || batch AS root,
 replace(path,'/Users/aloksubbarao/.' || source,root) AS target
FROM batches;
COPY (SELECT 'mkdir -p ' || chr(39) || replace(parse_dirpath(target),chr(39),chr(39)||'"'||chr(39)||'"'||chr(39)) || chr(39)
 || chr(10) || 'ln -s ' || chr(39) || replace(path,chr(39),chr(39)||'"'||chr(39)||'"'||chr(39)) || chr(39) || ' '
 || chr(39) || replace(target,chr(39),chr(39)||'"'||chr(39)||'"'||chr(39)) || chr(39)
 FROM stream_pending_files ORDER BY source,batch,path)
TO '| /bin/bash' (FORMAT csv,HEADER false,QUOTE '');
SET VARIABLE stream_normalization = (SELECT content FROM read_text(getvariable('server_dir') || '/server/agent_stream_normalize.sql'));
CREATE OR REPLACE TEMP TABLE stream_load_jobs AS
WITH roots AS (SELECT DISTINCT source,batch,root FROM stream_pending_files),
reader AS (
 SELECT *, replace(replace($reader$
WITH native AS (
 SELECT *, CASE WHEN list_contains(list_transform(
 ['business-profile','business_profile','customer_name','insured_name','policy_number'],
 term -> contains(lower(coalesce(message_content,'') || coalesce(tool_input,'') ||
 coalesce(cwd,'') || coalesce(project_path,'') || coalesce(project_dir,'') ||
 coalesce(parse_error,'')),term)),true) THEN true ELSE false END AS privacy_redacted
 FROM read_conversations(path := '@ROOT@',source := '@SOURCE@')
)
SELECT '@SOURCE@' AS system,
 * EXCLUDE (raw_event,metadata,input_tokens,output_tokens,cache_creation_tokens,cache_read_tokens,reasoning_tokens,
 file_path,file_name,message_content,tool_input,parse_error),
 replace(file_path,'@ROOT@','/Users/aloksubbarao/.@SOURCE@') AS file_path,
 replace(file_name,'@ROOT@','/Users/aloksubbarao/.@SOURCE@') AS file_name,
 CASE WHEN privacy_redacted AND message_content <> '' THEN '[redacted: client-data boundary]' ELSE message_content END AS message_content,
 CASE WHEN privacy_redacted AND tool_input <> '' THEN '[redacted: client-data boundary]' ELSE tool_input END AS tool_input,
 CASE WHEN privacy_redacted AND parse_error <> '' THEN '[redacted: client-data boundary]' ELSE parse_error END AS parse_error
FROM native
$reader$,'@ROOT@',replace(root,chr(39),chr(39)||chr(39))),'@SOURCE@',source) AS reader_sql
 FROM roots
)
SELECT source,batch,
 'CREATE OR REPLACE TEMP TABLE stream_source AS FROM quack_query(' ||
 chr(39) || 'quack:127.0.0.1:19494' || chr(39) || ', $native$' || reader_sql ||
 '$native$,token := getenv(' || chr(39) || 'QUACK_TOKEN' || chr(39) || '));' ||
 chr(10) || getvariable('stream_normalization') || chr(10) ||
 $write$
CREATE OR REPLACE TEMP TABLE stream_assert AS
 SELECT CASE WHEN count(id)=0 THEN error('native provider batch is empty')
 WHEN count(id) <> count(DISTINCT id) THEN error('duplicate normalized IDs')
 ELSE true END AS valid FROM stream_changed_delta;
CREATE TABLE IF NOT EXISTS agent.stream AS SELECT * FROM stream_changed_delta WHERE false;
ALTER TABLE agent.stream ADD COLUMN IF NOT EXISTS privacy_redacted BOOLEAN;
DELETE FROM agent.stream WHERE (system,file_path) IN (SELECT DISTINCT system,file_path FROM stream_source);
INSERT INTO agent.stream BY NAME FROM stream_changed_delta;
INSERT INTO agent.stream_ingest_batches BY NAME
 SELECT '@RUN@'::UUID AS run_id,'@SOURCE@' AS source,@BATCH@::BIGINT AS batch,
 max(source_rows) AS source_rows,max(normalized_rows) AS normalized_rows,now() AS completed_at
 FROM (SELECT count(1) AS source_rows,NULL::BIGINT AS normalized_rows FROM stream_source
 UNION ALL SELECT NULL::BIGINT,count(id) FROM stream_changed_delta);
SELECT count(id) AS stream_rows FROM agent.stream;
$write$ AS sql
FROM reader;
UPDATE stream_load_jobs SET sql=replace(replace(replace(sql,'@RUN@',
 (SELECT run_id::VARCHAR FROM stream_run)),'@SOURCE@',source),'@BATCH@',batch::VARCHAR);
SET VARIABLE stream_job_dir = getvariable('stream_work_root') || '/jobs';
COPY (SELECT 'mkdir -p "' || getvariable('stream_job_dir') || '"; printf %s ' ||
 chr(39) || replace(json_object('sql',sql)::VARCHAR,chr(39),chr(39)||'"'||chr(39)||'"'||chr(39)) || chr(39) ||
 ' > "' || getvariable('stream_job_dir') || '/' || source || '_' || lpad(batch::VARCHAR,4,'0') || '.json"'
 FROM stream_load_jobs ORDER BY source,batch)
TO '| /bin/bash' (FORMAT csv,HEADER false,QUOTE '');
SET VARIABLE stream_submit_command =
 'set -e; if [ -d "' || getvariable('stream_job_dir') || '" ]; then find "' || getvariable('stream_job_dir') ||
 '" -name "*.json" -type f | sort | while IFS= read -r job; do ' ||
 'attempt=0; while :; do attempt=$((attempt+1)); ' ||
 'code=$(curl --silent --show-error --max-time 300 -o "$job.receipt" -w "%{http_code}" ' ||
 '-H "Content-Type: application/json" --data-binary @"$job" http://localhost:9495/sql); ' ||
 'if [ "$code" = 200 ]; then cat "$job.receipt"; printf "\n"; break; fi; ' ||
 'body=$(cat "$job.receipt"); case "$body" in ' ||
 '*"Could not connect to server"*|*"Failed to send message"*) ' ||
 'if [ "$attempt" -lt 3 ]; then sleep 2; continue; fi;; esac; ' ||
 'printf "%s\n" "$body" >&2; exit 1; done; done; fi |';
CREATE OR REPLACE TEMP TABLE stream_submit_receipt AS FROM read_text(getvariable('stream_submit_command'));
CREATE OR REPLACE TEMP TABLE stream_totals AS
 SELECT count(id) AS stream_rows,max(ts) AS source_updated_through FROM agent.stream;
CREATE OR REPLACE TEMP TABLE stream_batch_totals AS
 SELECT sum(source_rows) AS source_rows,sum(normalized_rows) AS normalized_rows
 FROM agent.stream_ingest_batches WHERE run_id=(SELECT run_id FROM stream_run);
CREATE OR REPLACE TEMP TABLE stream_summary AS
 SELECT max(stream_rows) AS stream_rows,max(source_updated_through) AS source_updated_through,
 max(source_rows) AS source_rows,max(normalized_rows) AS normalized_rows
 FROM (SELECT *,NULL::BIGINT AS source_rows,NULL::BIGINT AS normalized_rows FROM stream_totals
 UNION ALL BY NAME FROM stream_batch_totals);
CREATE OR REPLACE TEMP TABLE stream_coverage_assert AS
 SELECT CASE WHEN count(id)=0 THEN error('stream is empty')
 WHEN count(id) <> count(DISTINCT id) THEN error('stream has duplicate IDs')
 ELSE true END AS valid FROM agent.stream;
UPDATE agent.stream_refresh AS r SET
 completed_at=now(),status='success',source_updated_through=s.source_updated_through,
 source_rows=coalesce(s.source_rows,0),normalized_rows=coalesce(s.normalized_rows,0),
 stream_rows=s.stream_rows,mutated_rows=s.normalized_rows
 FROM stream_summary s
 WHERE r.run_id=(SELECT run_id FROM stream_run);
-- Remove only the generated run directory (symlinks and SQL jobs, never source transcripts).
SET VARIABLE stream_cleanup_command = 'rm -r "' || getvariable('stream_work_root') || '" |';
FROM read_text(getvariable('stream_cleanup_command'));

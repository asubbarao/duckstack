-- Run this complete body through dev's Quack door after lake is attached.
-- Source: original native read_conversations rows on reader :19494, never agent.stream.
-- Claude/Desktop require roots; Codex accepts literal JSONL paths (measured).
-- Root reads stream into a TEMP table, never an HTTP array of source observations.
-- Claude is ~1.94 GB/815 files (2026-10-08); the caller owns scheduling this full read.
-- Codex files use size/mtime cursors and reconcile daily, independently of event time.
-- Set lake_agent_full_rescan=true in this body to reconcile immediately.
-- Receipts and generated jobs remain under ~/.duck/lake_agent_capture/<run>/.
-- No uncertain write is retried automatically. Rerunning is fingerprint-idempotent.
-- A dev-local UNIQUE lock enforces one owner; DuckLake has no UNIQUE guard.
-- Failure keeps the owner row. Inspect its retained job receipts before clearing
-- that exact run_id; no timeout can safely prove an uncertain capture stopped.
LOAD shellfs;
LOAD hostfs;
LOAD quack;
CREATE SCHEMA IF NOT EXISTS lake.raw;
CREATE TABLE IF NOT EXISTS lake.raw.agent_capture_files (
 system VARCHAR, path_sha256 VARCHAR, bytes BIGINT, modified_at TIMESTAMPTZ,
 captured_at TIMESTAMPTZ, reconciled_at TIMESTAMPTZ);
CREATE TABLE IF NOT EXISTS lake.raw.agent_capture_batches (
 run_id UUID, batch BIGINT, system VARCHAR, path_sha256 VARCHAR,
 source_rows BIGINT, inserted_rows BIGINT, privacy_redacted_rows BIGINT,
 completed_at TIMESTAMPTZ);

CREATE OR REPLACE TEMP TABLE lake_agent_run AS
 SELECT uuid() AS run_id, now() AS started_at;
SET VARIABLE lake_agent_work_root = (
 SELECT '/Users/aloksubbarao/.duck/lake_agent_capture/' || run_id FROM lake_agent_run);
SET VARIABLE lake_agent_run_id = (SELECT run_id::VARCHAR FROM lake_agent_run);
CREATE SCHEMA IF NOT EXISTS agent;
CREATE TABLE IF NOT EXISTS agent.lake_capture_lock (
 name VARCHAR PRIMARY KEY,run_id UUID,started_at TIMESTAMPTZ);
BEGIN;
INSERT INTO agent.lake_capture_lock BY NAME
 SELECT 'original-agent-observations' AS name,* FROM lake_agent_run
 ON CONFLICT DO NOTHING;
CREATE OR REPLACE TEMP TABLE lake_agent_claim AS
 SELECT CASE WHEN run_id::VARCHAR=getvariable('lake_agent_run_id') THEN true
 ELSE error('original agent capture already has an owner; inspect its receipts before recovery') END AS claimed
 FROM agent.lake_capture_lock WHERE name='original-agent-observations';
COMMIT;
-- The reader validates paths at execution even when a schema-only bind succeeds.
FROM read_text('mkdir -p /Users/aloksubbarao/.duck/lake_agent_capture/empty |');

-- DESCRIBE binds the native schema without reading a transcript. Parameter defaults:
-- path NULL, source NULL (auto-detection), include_archived false; all explicit here.
CREATE OR REPLACE TEMP TABLE lake_agent_columns AS
 SELECT row_number() OVER () AS position, column_name, column_type
 FROM quack_query('quack:127.0.0.1:19494', $describe$
 DESCRIBE SELECT 'codex' AS system,* FROM read_conversations(
 path := '/Users/aloksubbarao/.duck/lake_agent_capture/empty',
 source := 'codex',include_archived := true)
 $describe$,token := getenv('QUACK_TOKEN'));
-- Redact every string in a flagged row, including raw_event, metadata, paths and
-- parser diagnostics. Hashing happens on the private reader before this projection.
SET VARIABLE lake_agent_projection = (
 SELECT string_agg(CASE
 WHEN column_name IN ('system','source') THEN 'n."' || column_name || '"'
 WHEN column_type='VARCHAR' THEN
 'CASE WHEN privacy_redacted AND n."' || column_name || '" IS NOT NULL '
 || 'THEN ''[redacted: client-data boundary]'' ELSE n."' || column_name
 || '" END AS "' || column_name || '"'
 ELSE 'n."' || column_name || '"' END,',' ORDER BY position)
 FROM lake_agent_columns);

-- The complete original row hash includes file_path, offset/line/ordinal and all
-- metadata. An occurrence suffix also preserves exact duplicate reader rows.
-- Neither timestamps nor message UUIDs serve as ingestion cursors.
SET VARIABLE lake_agent_reader_template = $reader$
WITH original AS (
 SELECT '@SYSTEM@' AS system,* FROM read_conversations(
 path := '@PATH@',source := '@SYSTEM@',include_archived := true)
), fingerprinted AS (
 SELECT *,sha256(to_json(original)::VARCHAR) AS original_sha256,
 list_contains(list_transform(
 ['business-profile','business_profile','customer_name','insured_name','policy_number'],
 term -> contains(lower(to_json(original)::VARCHAR),term)),true) AS privacy_redacted
 FROM original
), numbered AS (
 SELECT *,row_number() OVER (PARTITION BY original_sha256
 ORDER BY ordinal,byte_offset,line_number) AS observation_occurrence FROM fingerprinted
)
SELECT @PROJECTION@, privacy_redacted,observation_occurrence,
 sha256(original_sha256 || ':' || observation_occurrence::VARCHAR) AS observation_fingerprint
FROM numbered n
$reader$;

-- Native fields stay typed, and a future schema change fails BY NAME rather than
-- silently discarding newly exposed source columns.
SET VARIABLE lake_agent_empty_sql = replace(replace(replace(
 getvariable('lake_agent_reader_template'),'@SYSTEM@','codex'),
 '@PATH@','/Users/aloksubbarao/.duck/lake_agent_capture/empty'),
 '@PROJECTION@',getvariable('lake_agent_projection'));
CREATE TABLE IF NOT EXISTS lake.raw.agent_observations AS
 SELECT *,NULL::UUID AS capture_run_id,NULL::TIMESTAMPTZ AS captured_at
 FROM quack_query('quack:127.0.0.1:19494',getvariable('lake_agent_empty_sql'),
 token := getenv('QUACK_TOKEN'));

CREATE OR REPLACE TEMP TABLE lake_agent_inventory AS
 SELECT 'codex' AS system,file AS path,sha256(file) AS path_sha256,
 file_size(file)::BIGINT AS bytes,file_last_modified(file) AT TIME ZONE 'UTC' AS modified_at
 FROM glob(['/Users/aloksubbarao/.codex/sessions/**/*.jsonl',
 '/Users/aloksubbarao/.codex/archived_sessions/**/*.jsonl']);
CREATE OR REPLACE TEMP TABLE lake_agent_pending AS
 SELECT i.*,CASE WHEN coalesce(getvariable('lake_agent_full_rescan')::BOOLEAN,false)
 THEN true WHEN f.reconciled_at IS NULL THEN true
 ELSE f.reconciled_at < now()-INTERVAL '1 day' END AS reconcile
 FROM lake_agent_inventory i
 LEFT JOIN lake.raw.agent_capture_files f USING (system,path_sha256)
 WHERE CASE WHEN coalesce(getvariable('lake_agent_full_rescan')::BOOLEAN,false) THEN true
 WHEN f.path_sha256 IS NULL THEN true
 WHEN i.bytes IS DISTINCT FROM f.bytes THEN true
 WHEN i.modified_at IS DISTINCT FROM f.modified_at THEN true
 WHEN f.reconciled_at IS NULL THEN true
 ELSE f.reconciled_at < now()-INTERVAL '1 day' END;
CREATE OR REPLACE TEMP TABLE lake_agent_inputs AS
 SELECT system,path,path_sha256,bytes,modified_at,reconcile FROM lake_agent_pending
 UNION ALL BY NAME
 SELECT system,path,sha256(path) AS path_sha256,NULL::BIGINT AS bytes,
 NULL::TIMESTAMPTZ AS modified_at,true AS reconcile
 FROM (VALUES ('claude','/Users/aloksubbarao/.claude'),
 ('claude-desktop','/Users/aloksubbarao/Library/Application Support/Claude')) roots(system,path);
CREATE OR REPLACE TEMP TABLE lake_agent_jobs AS
 SELECT row_number() OVER (ORDER BY system,path) AS batch,*,
 replace(replace(replace(getvariable('lake_agent_reader_template'),
 '@SYSTEM@',system),'@PATH@',replace(path,chr(39),chr(39)||chr(39))),
 '@PROJECTION@',getvariable('lake_agent_projection')) AS reader_sql
 FROM lake_agent_inputs;

-- Each job owns a transaction in one catalog: publication and its file cursor
-- succeed together. A file changing during the read remains pending next time.
SET VARIABLE lake_agent_write_template = $write$
CREATE OR REPLACE TEMP TABLE lake_agent_source AS
 SELECT *, '@RUN@'::UUID AS capture_run_id,now() AS captured_at
 FROM quack_query('quack:127.0.0.1:19494',$native$@READER@$native$,
 token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE TEMP TABLE lake_agent_delta AS
 SELECT s.* FROM lake_agent_source s ANTI JOIN lake.raw.agent_observations o
 USING (observation_fingerprint);
BEGIN;
INSERT INTO lake.raw.agent_observations BY NAME FROM lake_agent_delta;
INSERT INTO lake.raw.agent_capture_batches BY NAME
 WITH totals AS (
 SELECT count(observation_fingerprint) AS source_rows,NULL::BIGINT AS inserted_rows,
 count(observation_fingerprint) FILTER (WHERE privacy_redacted) AS privacy_redacted_rows
 FROM lake_agent_source
 UNION ALL BY NAME SELECT NULL::BIGINT AS source_rows,
 count(observation_fingerprint) AS inserted_rows,NULL::BIGINT AS privacy_redacted_rows
 FROM lake_agent_delta)
 SELECT '@RUN@'::UUID AS run_id,@BATCH@::BIGINT AS batch,'@SYSTEM@' AS system,
 '@HASH@' AS path_sha256,sum(source_rows) AS source_rows,
 sum(inserted_rows) AS inserted_rows,sum(privacy_redacted_rows) AS privacy_redacted_rows,
 now() AS completed_at FROM totals;
@CURSOR@
COMMIT;
SELECT run_id,batch,system,source_rows,inserted_rows,privacy_redacted_rows,completed_at
FROM lake.raw.agent_capture_batches WHERE run_id='@RUN@'::UUID AND batch=@BATCH@;
$write$;
-- No source payload enters receipts; the complete generated program stays local.
CREATE OR REPLACE TEMP TABLE lake_agent_programs AS
 SELECT j.*,replace(replace(replace(replace(replace(replace(
 getvariable('lake_agent_write_template'),'@READER@',reader_sql),
 '@RUN@',getvariable('lake_agent_run_id')),'@BATCH@',batch::VARCHAR),'@SYSTEM@',system),
 '@HASH@',path_sha256),
 '@CURSOR@',CASE WHEN system='codex' THEN
 'DELETE FROM lake.raw.agent_capture_files WHERE system=''codex'' AND path_sha256=''' || path_sha256 || ''';'
 || 'INSERT INTO lake.raw.agent_capture_files BY NAME SELECT ''codex'' AS system,''' || path_sha256
 || ''' AS path_sha256,' || bytes || '::BIGINT AS bytes,''' || modified_at
 || '''::TIMESTAMPTZ AS modified_at,now() AS captured_at,'
 || CASE WHEN reconcile THEN 'now() AS reconciled_at ' ELSE
 'reconciled_at FROM lake_agent_previous_cursor ' END
 || 'WHERE file_size(''' || replace(path,chr(39),chr(39)||chr(39))
 || ''')::BIGINT=' || bytes || ' AND file_last_modified('''
 || replace(path,chr(39),chr(39)||chr(39)) || ''') AT TIME ZONE ''UTC''='''
 || modified_at || '''::TIMESTAMPTZ;'
 ELSE '' END) AS sql
 FROM lake_agent_jobs j;
-- Previous reconciliation time must be read before deleting the cursor.
UPDATE lake_agent_programs SET sql=
 'CREATE OR REPLACE TEMP TABLE lake_agent_previous_cursor AS SELECT reconciled_at '
 || 'FROM lake.raw.agent_capture_files WHERE system=''' || system
 || ''' AND path_sha256=''' || path_sha256 || ''';' || chr(10) || sql;

-- ShellFS submits sequentially through the selected server's Quack door. The HTTP
-- route has an execution deadline, so a stable ephemeral client transports each
-- retained JSON program directly. Result, stderr and exit code survive failures.
SET VARIABLE lake_agent_mkdir='mkdir -p "' || getvariable('lake_agent_work_root') || '" |';
FROM read_text(getvariable('lake_agent_mkdir'));
COPY (SELECT 'printf %s ' || chr(39)
 || replace(json_object('sql',sql)::VARCHAR,chr(39),chr(39)||'"'||chr(39)||'"'||chr(39))
 || chr(39) || ' > "' || getvariable('lake_agent_work_root') || '/'
 || lpad(batch::VARCHAR,7,'0') || '.json"' FROM lake_agent_programs ORDER BY batch)
TO '| /bin/bash' (FORMAT csv,HEADER false,QUOTE '');
COPY (SELECT $transport$
SET extension_directory=getenv('HOME') || '/.duck/extensions';
LOAD quack;
SET VARIABLE lake_agent_job_sql=(SELECT sql FROM read_json(getenv('LAKE_AGENT_JOB')));
FROM quack_query('quack:localhost:9494',getvariable('lake_agent_job_sql'),
 token := getenv('QUACK_TOKEN'));
$transport$)
TO (getvariable('lake_agent_work_root') || '/submit.sql')
 (FORMAT csv,HEADER false,QUOTE '');
SET VARIABLE lake_agent_submit =
 'set -e; for job in "' || getvariable('lake_agent_work_root') || '"/*.json; do '
 || '[ -f "$job" ] || continue; '
 || 'code=0; LAKE_AGENT_JOB="$job" /opt/homebrew/bin/duckdb :memory: '
 || '-init /dev/null -bail -json -f "' || getvariable('lake_agent_work_root')
 || '/submit.sql" > "$job.receipt" 2> "$job.stderr" || code=$?; '
 || 'printf ''%s\n'' "$code" > "$job.status"; '
 || 'cat "$job.receipt"; printf ''\n''; '
 || 'if [ "$code" != 0 ]; then cat "$job.stderr" >&2; exit "$code"; fi; done |';
FROM read_text(getvariable('lake_agent_submit'));
DELETE FROM agent.lake_capture_lock
 WHERE name='original-agent-observations' AND run_id::VARCHAR=getvariable('lake_agent_run_id');

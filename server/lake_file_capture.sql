-- Submit one complete body to dev :9495/sql after lake is attached; no scheduler here.
-- Optional variables: lake_file_csv_glob, lake_file_otlp_glob, lake_file_max_files
-- (default 16; increase for baseline), lake_file_full_rescan (default false).
-- Unchanged files are skipped until daily reconciliation. Changed CSVs are parsed
-- into original typed rows, never persisted as a repeatedly copied giant file blob.
-- Per-row original hashes plus occurrence preserve duplicates and content revisions.
-- Privacy hashes precede redaction; flagged string fields / OTLP payloads are erased.
-- A failed/uncertain submission keeps the lock and local jobs/receipts: inspect them
-- before clearing that exact owner. No timeout recovery and no automatic retry.
LOAD shellfs; LOAD hostfs;
CREATE SCHEMA IF NOT EXISTS lake.raw;
CREATE TABLE IF NOT EXISTS lake.raw.native_log_events (
 context_id UBIGINT,scope VARCHAR,connection_id UBIGINT,transaction_id UBIGINT,
 query_id UBIGINT,thread_id UBIGINT,timestamp TIMESTAMPTZ,type VARCHAR,log_level VARCHAR,message VARCHAR,
 source_filename VARCHAR,source_filename_sha256 VARCHAR,original_sha256 VARCHAR,
 observation_occurrence BIGINT,observation_fingerprint VARCHAR,privacy_redacted BOOLEAN,
 capture_run_id UUID,captured_at TIMESTAMPTZ);
CREATE TABLE IF NOT EXISTS lake.raw.otlp_files (
 source_filename VARCHAR,source_filename_sha256 VARCHAR,original_sha256 VARCHAR,
 observation_occurrence BIGINT,observation_fingerprint VARCHAR,privacy_redacted BOOLEAN,
 original_json VARCHAR,payload JSON,capture_run_id UUID,captured_at TIMESTAMPTZ);
CREATE TABLE IF NOT EXISTS lake.raw.file_capture_files (
 kind VARCHAR,path_sha256 VARCHAR,bytes BIGINT,modified_at TIMESTAMPTZ,
 captured_at TIMESTAMPTZ,reconciled_at TIMESTAMPTZ);
CREATE TABLE IF NOT EXISTS lake.raw.file_capture_batches (
 run_id UUID,batch BIGINT,kind VARCHAR,path_sha256 VARCHAR,source_rows BIGINT,
 inserted_rows BIGINT,privacy_redacted_rows BIGINT,completed_at TIMESTAMPTZ);
CREATE OR REPLACE TEMP TABLE lake_file_run AS SELECT uuid() AS run_id,now() AS started_at;
SET VARIABLE lake_file_run_id=(SELECT run_id::VARCHAR FROM lake_file_run);
SET VARIABLE lake_file_work_root='/Users/aloksubbarao/.duck/lake_file_capture/' || getvariable('lake_file_run_id');
CREATE SCHEMA IF NOT EXISTS agent;
CREATE TABLE IF NOT EXISTS agent.lake_capture_lock (name VARCHAR PRIMARY KEY,run_id UUID,started_at TIMESTAMPTZ);
BEGIN;
INSERT INTO agent.lake_capture_lock BY NAME SELECT 'native-file-capture' AS name,* FROM lake_file_run
 ON CONFLICT DO NOTHING;
CREATE OR REPLACE TEMP TABLE lake_file_claim AS
 SELECT CASE WHEN run_id::VARCHAR=getvariable('lake_file_run_id') THEN true
 ELSE error('native file capture already owned; inspect retained receipts before recovery') END AS claimed
 FROM agent.lake_capture_lock WHERE name='native-file-capture';
COMMIT;
CREATE OR REPLACE TEMP TABLE lake_file_inventory AS
 WITH files AS (
 SELECT 'native' AS kind,file AS path FROM glob(coalesce(getvariable('lake_file_csv_glob')::VARCHAR,
 '/Users/aloksubbarao/.duck/logs/duckdb_log*.csv'))
 UNION ALL SELECT 'otlp',file FROM glob(coalesce(getvariable('lake_file_otlp_glob')::VARCHAR,
 '/Users/aloksubbarao/.duck/otlp/signal=*/**/*.json')))
 SELECT *,sha256(path) AS path_sha256,file_size(path)::BIGINT AS bytes,
 file_last_modified(path) AT TIME ZONE 'UTC' AS modified_at FROM files;
CREATE OR REPLACE TEMP TABLE lake_file_pending AS
 SELECT i.*,f.reconciled_at,CASE WHEN coalesce(getvariable('lake_file_full_rescan')::BOOLEAN,false)
 THEN true WHEN f.reconciled_at IS NULL THEN true ELSE f.reconciled_at < now()-INTERVAL '1 day' END AS reconcile
 FROM lake_file_inventory i LEFT JOIN lake.raw.file_capture_files f USING (kind,path_sha256)
 WHERE CASE WHEN coalesce(getvariable('lake_file_full_rescan')::BOOLEAN,false) THEN true
 WHEN f.path_sha256 IS NULL THEN true WHEN i.bytes IS DISTINCT FROM f.bytes THEN true
 WHEN i.modified_at IS DISTINCT FROM f.modified_at THEN true
 WHEN f.reconciled_at IS NULL THEN true ELSE f.reconciled_at < now()-INTERVAL '1 day' END
 ORDER BY coalesce(f.captured_at,TIMESTAMPTZ 'epoch'),i.modified_at,i.path
 LIMIT coalesce(getvariable('lake_file_max_files')::BIGINT,16);
SET VARIABLE lake_file_native_reader=$native$
WITH original AS (
 SELECT * FROM read_csv('@PATH@',header := true,delim := ',',quote := '"',escape := '"',
 maximum_line_size := 67108864,columns := {'context_id':'UBIGINT','scope':'VARCHAR',
 'connection_id':'UBIGINT','transaction_id':'UBIGINT','query_id':'UBIGINT','thread_id':'UBIGINT',
 'timestamp':'TIMESTAMPTZ','type':'VARCHAR','log_level':'VARCHAR','message':'VARCHAR'})
), hashed AS (
 SELECT *,sha256(to_json(original)::VARCHAR) AS original_sha256,
 list_contains(list_transform(['business-profile','business_profile','customer_name','insured_name','policy_number'],
 term -> contains(lower('@PATH@' || to_json(original)::VARCHAR),term)),true) AS privacy_redacted FROM original
), numbered AS (
 SELECT *,row_number() OVER (PARTITION BY original_sha256) AS observation_occurrence FROM hashed)
SELECT context_id,CASE WHEN privacy_redacted THEN NULL ELSE scope END AS scope,
 connection_id,transaction_id,query_id,thread_id,timestamp,
 CASE WHEN privacy_redacted THEN NULL ELSE type END AS type,
 CASE WHEN privacy_redacted THEN NULL ELSE log_level END AS log_level,
 CASE WHEN privacy_redacted THEN NULL ELSE message END AS message,
 CASE WHEN privacy_redacted THEN NULL ELSE '@PATH@' END AS source_filename,
 '@HASH@' AS source_filename_sha256,original_sha256,observation_occurrence,
 sha256('@HASH@' || ':' || original_sha256 || ':' || observation_occurrence::VARCHAR) AS observation_fingerprint,
 privacy_redacted FROM numbered
$native$;
SET VARIABLE lake_file_otlp_reader=$otlp$
WITH original AS (SELECT content FROM read_text('@PATH@')),hashed AS (
 SELECT *,sha256(content) AS original_sha256,
 list_contains(list_transform(['business-profile','business_profile','customer_name','insured_name','policy_number'],
 term -> contains(lower('@PATH@' || content),term)),true) AS privacy_redacted FROM original)
SELECT CASE WHEN privacy_redacted THEN NULL ELSE '@PATH@' END AS source_filename,
 '@HASH@' AS source_filename_sha256,original_sha256,1::BIGINT AS observation_occurrence,
 sha256('@HASH@' || ':' || original_sha256 || ':1') AS observation_fingerprint,privacy_redacted,
 CASE WHEN privacy_redacted THEN NULL ELSE content END AS original_json,
 CASE WHEN privacy_redacted THEN NULL ELSE content::JSON END AS payload FROM hashed
$otlp$;
SET VARIABLE lake_file_write_template=$write$
CREATE OR REPLACE TEMP TABLE lake_file_source AS
 SELECT *, '@RUN@'::UUID AS capture_run_id,now() AS captured_at FROM (@READER@) source;
CREATE OR REPLACE TEMP TABLE lake_file_delta AS SELECT s.* FROM lake_file_source s
 ANTI JOIN lake.raw.@TABLE@ USING (observation_fingerprint);
BEGIN;
INSERT INTO lake.raw.@TABLE@ BY NAME FROM lake_file_delta;
INSERT INTO lake.raw.file_capture_batches BY NAME
 WITH totals AS (
 SELECT count(observation_fingerprint) AS source_rows,NULL::BIGINT AS inserted_rows,
 count(observation_fingerprint) FILTER (WHERE privacy_redacted) AS privacy_redacted_rows FROM lake_file_source
 UNION ALL BY NAME SELECT NULL::BIGINT AS source_rows,count(observation_fingerprint) AS inserted_rows,
 NULL::BIGINT AS privacy_redacted_rows FROM lake_file_delta)
 SELECT '@RUN@'::UUID AS run_id,@BATCH@::BIGINT AS batch,'@KIND@' AS kind,'@HASH@' AS path_sha256,
 sum(source_rows) AS source_rows,sum(inserted_rows) AS inserted_rows,sum(privacy_redacted_rows) AS privacy_redacted_rows,
 now() AS completed_at FROM totals;
DELETE FROM lake.raw.file_capture_files WHERE kind='@KIND@' AND path_sha256='@HASH@';
INSERT INTO lake.raw.file_capture_files BY NAME SELECT '@KIND@' AS kind,'@HASH@' AS path_sha256,
 @BYTES@::BIGINT AS bytes,'@MTIME@'::TIMESTAMPTZ AS modified_at,now() AS captured_at,@RECONCILED@ AS reconciled_at;
COMMIT;
SELECT source_rows,inserted_rows,privacy_redacted_rows FROM lake.raw.file_capture_batches
 WHERE run_id='@RUN@'::UUID AND batch=@BATCH@;
$write$;
CREATE OR REPLACE TEMP TABLE lake_file_jobs AS
 SELECT row_number() OVER (ORDER BY coalesce(reconciled_at,TIMESTAMPTZ 'epoch'),modified_at,path) AS batch,*,
 replace(replace(CASE WHEN kind='native' THEN getvariable('lake_file_native_reader')
 ELSE getvariable('lake_file_otlp_reader') END,'@PATH@',replace(path,chr(39),chr(39)||chr(39))),
 '@HASH@',path_sha256) AS reader_sql FROM lake_file_pending;
CREATE OR REPLACE TEMP TABLE lake_file_programs AS
 SELECT *,replace(replace(replace(replace(replace(replace(replace(replace(replace(
 getvariable('lake_file_write_template'),'@READER@',reader_sql),'@TABLE@',
 CASE WHEN kind='native' THEN 'native_log_events' ELSE 'otlp_files' END),'@RUN@',getvariable('lake_file_run_id')),
 '@BATCH@',batch::VARCHAR),'@KIND@',kind),'@HASH@',path_sha256),'@BYTES@',bytes::VARCHAR),
 '@MTIME@',modified_at::VARCHAR),'@RECONCILED@',CASE WHEN reconcile THEN 'now()' ELSE
 chr(39)||reconciled_at::VARCHAR||chr(39)||'::TIMESTAMPTZ' END) AS sql FROM lake_file_jobs;
SET VARIABLE lake_file_mkdir='mkdir -p "' || getvariable('lake_file_work_root') || '" |';
FROM read_text(getvariable('lake_file_mkdir'));
COPY (SELECT 'printf %s ' || chr(39) || replace(json_object('sql',sql)::VARCHAR,
 chr(39),chr(39)||'"'||chr(39)||'"'||chr(39)) || chr(39) || ' > "' || getvariable('lake_file_work_root')
 || '/' || lpad(batch::VARCHAR,7,'0') || '.json"' FROM lake_file_programs ORDER BY batch)
 TO '| /bin/bash' (FORMAT csv,HEADER false,QUOTE '');
-- The ephemeral client transports one bundle; its database holds no source state.
-- Direct Quack avoids the HTTP executor deadline on large native log files.
SET VARIABLE lake_file_client_sql=$client$
SET extension_directory=getenv('HOME') || '/.duck/extensions';
LOAD quack;
SET VARIABLE capture_sql=(SELECT sql FROM read_json(getenv('LAKE_FILE_JOB')));
FROM quack_query('quack:localhost:9494',getvariable('capture_sql'),token:=getenv('QUACK_TOKEN'));
$client$;
COPY (SELECT getvariable('lake_file_client_sql'))
 TO (getvariable('lake_file_work_root') || '/client.sql') (FORMAT csv,HEADER false,QUOTE '',ESCAPE '');
SET VARIABLE lake_file_submit='set -e; for job in "' || getvariable('lake_file_work_root') || '"/*.json; do '
 || '[ -f "$job" ] || continue; if LAKE_FILE_JOB="$job" /opt/homebrew/bin/duckdb '
 || '-init /dev/null :memory: -bail -json -f "' || getvariable('lake_file_work_root')
 || '/client.sql" >"$job.receipt" 2>"$job.stderr"; then code=0; else code=$?; fi; '
 || 'printf ''%s\n'' "$code" > "$job.status"; cat "$job.receipt"; printf ''\n''; [ "$code" = 0 ] || exit "$code"; done |';
FROM read_text(getvariable('lake_file_submit'));
DELETE FROM agent.lake_capture_lock WHERE name='native-file-capture' AND run_id::VARCHAR=getvariable('lake_file_run_id');

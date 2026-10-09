-- SQL-only integration; CATALOG_SOURCE_ROOT=<checkout> duckdb :memory: -json -f this_file.sql.
-- The real capture preparation and generated publication SQL execute in one isolated
-- child connection. Only source globs change; no live logs, lake, HTTP or scheduler.
LOAD shellfs; LOAD hostfs;
SET VARIABLE file_test_root='/tmp/lake-file-test-' || uuid()::VARCHAR;
FROM read_text('mkdir -p "' || getvariable('file_test_root') || '" |');
CREATE TEMP TABLE fixture_native AS
SELECT 1::UBIGINT AS context_id,'CONNECTION' AS scope,2::UBIGINT AS connection_id,
 3::UBIGINT AS transaction_id,4::UBIGINT AS query_id,NULL::UBIGINT AS thread_id,
 TIMESTAMPTZ '2026-10-08 01:02:03+00' AS timestamp,'QueryLog' AS type,'INFO' AS log_level,
 'SELECT 42' AS message
UNION ALL SELECT 1,'CONNECTION',2,3,4,NULL,TIMESTAMPTZ '2026-10-08 01:02:03+00','QueryLog','INFO','SELECT 42'
UNION ALL SELECT 1,'CONNECTION',2,3,4,NULL,TIMESTAMPTZ '2026-10-08 01:02:03+00','QueryLog','INFO','SELECT customer_name';
COPY fixture_native TO (getvariable('file_test_root') || '/native.csv') (FORMAT csv,HEADER true);
COPY (SELECT '{ "resourceLogs": [], "keep": "original spacing" }')
 TO (getvariable('file_test_root') || '/clean.json') (FORMAT csv,HEADER false,QUOTE '',ESCAPE '');
COPY (SELECT '{"policy_number":"private"}')
 TO (getvariable('file_test_root') || '/private.json') (FORMAT csv,HEADER false,QUOTE '',ESCAPE '');
SET VARIABLE file_test_prepare=getvariable('file_test_root') || '/prepare.sql';
SET VARIABLE file_test_jobs=getvariable('file_test_root') || '/jobs.sql';
COPY (
 SELECT 'SET VARIABLE lake_file_csv_glob=' || chr(39) || getvariable('file_test_root') || '/native.csv' || chr(39) || ';'
 || 'SET VARIABLE lake_file_otlp_glob=' || chr(39) || getvariable('file_test_root') || '/*.json' || chr(39) || ';'
 || split_part(content,'SET VARIABLE lake_file_mkdir=',1)
 || 'COPY (SELECT string_agg(sql,chr(10) ORDER BY batch) FROM lake_file_programs) TO '
 || chr(39) || getvariable('file_test_jobs') || chr(39)
 || ' (FORMAT csv,HEADER false,QUOTE ' || chr(39)||chr(39) || ',ESCAPE ' || chr(39)||chr(39) || ');'
 FROM read_text(getenv('CATALOG_SOURCE_ROOT') || '/server/lake_file_capture.sql')
) TO (getvariable('file_test_prepare')) (FORMAT csv,HEADER false,QUOTE '',ESCAPE '');
SET VARIABLE file_test_program=getvariable('file_test_root') || '/test.sql';
COPY (SELECT $sql$
INSTALL ducklake; LOAD ducklake;
ATTACH 'ducklake::memory:' AS lake (DATA_PATH ('/tmp/lake-file-fixture-data-' || uuid()::VARCHAR),DATA_INLINING_ROW_LIMIT 0);
$sql$ || 'CREATE TEMP TABLE fixture_native AS FROM read_csv(' || chr(39)
 || getvariable('file_test_root') || '/native.csv' || chr(39) || ');' || chr(10)
 || '.read ' || getvariable('file_test_prepare') || chr(10)
 || '.read ' || getvariable('file_test_jobs') || chr(10) || $sql$
DELETE FROM agent.lake_capture_lock WHERE name='native-file-capture';
SELECT CASE WHEN count(observation_fingerprint)=3 AND count(message)=2
 AND count(observation_fingerprint) FILTER(WHERE privacy_redacted)=1
 THEN 'typed native and privacy passed' ELSE error('native count or redaction mismatch') END FROM lake.raw.native_log_events;
SELECT CASE WHEN list_sort(list(observation_occurrence))=[1,2]
 THEN 'exact duplicate occurrences retained' ELSE error('duplicates lost') END
 FROM lake.raw.native_log_events WHERE message='SELECT 42';
SELECT CASE WHEN count(observation_fingerprint)=2 AND count(original_json)=1 AND count(payload)=1
 THEN 'original OTLP and privacy passed' ELSE error('OTLP redaction mismatch') END FROM lake.raw.otlp_files;
SELECT CASE WHEN original_json='{ "resourceLogs": [], "keep": "original spacing" }'||chr(10)
 AND original_sha256=sha256(original_json) THEN 'exact JSON bytes retained'
 ELSE error('JSON original content lost') END FROM lake.raw.otlp_files WHERE NOT privacy_redacted;
$sql$ || '.read ' || getvariable('file_test_prepare') || chr(10) || $sql$
SELECT CASE WHEN count(path)=0 THEN 'metadata cursor skips exact rerun'
 ELSE error('unchanged file pending') END FROM lake_file_pending;
DELETE FROM agent.lake_capture_lock WHERE name='native-file-capture';
SET VARIABLE lake_file_full_rescan=true;
$sql$ || '.read ' || getvariable('file_test_prepare') || chr(10)
 || '.read ' || getvariable('file_test_jobs') || chr(10) || $sql$
SELECT CASE WHEN sum(inserted_rows)=0 THEN 'reconciliation inserts nothing'
 ELSE error('rerun inserted duplicates') END FROM lake.raw.file_capture_batches WHERE run_id::VARCHAR=getvariable('lake_file_run_id');
DELETE FROM agent.lake_capture_lock WHERE name='native-file-capture';
SET VARIABLE lake_file_full_rescan=false;
UPDATE lake.raw.file_capture_files SET reconciled_at=now()-INTERVAL '2 days';
$sql$ || '.read ' || getvariable('file_test_prepare') || chr(10) || $sql$
SELECT CASE WHEN count(path)=3 AND bool_and(reconcile) THEN 'daily reconciliation includes all files'
 ELSE error('daily reconciliation missed file') END FROM lake_file_pending;
DELETE FROM agent.lake_capture_lock WHERE name='native-file-capture';
$sql$ || 'COPY (SELECT ' || chr(39) || '{"resourceLogs":[],"revision":2}' || chr(39) || ') TO '
 || chr(39) || getvariable('file_test_root') || '/clean.json' || chr(39)
 || ' (FORMAT csv,HEADER false,QUOTE ' || chr(39)||chr(39) || ',ESCAPE ' || chr(39)||chr(39) || ');' || chr(10)
 || '.read ' || getvariable('file_test_prepare') || chr(10)
 || '.read ' || getvariable('file_test_jobs') || chr(10) || $sql$
SELECT CASE WHEN count(observation_fingerprint)=3 AND count(DISTINCT original_sha256)=3
 THEN 'OTLP file revisions preserved' ELSE error('changed file revision lost') END FROM lake.raw.otlp_files;
SELECT CASE WHEN count(context_id)=3 THEN 'native reruns remain unique'
 ELSE error('native duplicated on reconciliation') END FROM lake.raw.native_log_events;
DELETE FROM agent.lake_capture_lock WHERE name='native-file-capture';
INSERT INTO fixture_native BY NAME SELECT 1 AS context_id,'CONNECTION' AS scope,2 AS connection_id,
 3 AS transaction_id,4 AS query_id,NULL AS thread_id,TIMESTAMPTZ '2026-10-08 01:02:03+00' AS timestamp,
 'QueryLog' AS type,'INFO' AS log_level,'SELECT 43' AS message;
$sql$ || 'COPY fixture_native TO ' || chr(39) || getvariable('file_test_root') || '/native.csv' || chr(39)
 || ' (FORMAT csv,HEADER true);' || chr(10)
 || '.read ' || getvariable('file_test_prepare') || chr(10)
 || '.read ' || getvariable('file_test_jobs') || chr(10) || $sql$
SELECT CASE WHEN count(context_id)=4 AND count(context_id) FILTER(WHERE message='SELECT 43')=1
 THEN 'native appended event preserved' ELSE error('native revision lost') END FROM lake.raw.native_log_events;
DELETE FROM agent.lake_capture_lock WHERE name='native-file-capture';
$sql$ AS program)
 TO (getvariable('file_test_program')) (FORMAT csv,HEADER false,QUOTE '',ESCAPE '');
SELECT content AS fixture_results FROM read_text('/opt/homebrew/bin/duckdb :memory: -bail -csv -noheader -f '
 || getvariable('file_test_program') || ' 2>&1 |');
-- The failing second claimant must leave the original owner, even after rollback.
SET VARIABLE file_test_lock_program=getvariable('file_test_root') || '/lock.sql';
COPY (
 SELECT $sql$
INSTALL ducklake; LOAD ducklake;
ATTACH 'ducklake::memory:' AS lake (DATA_PATH ('/tmp/lake-file-lock-data-' || uuid()::VARCHAR));
$sql$ || split_part(content,'CREATE OR REPLACE TEMP TABLE lake_file_inventory AS',1)
 || split_part(content,'CREATE OR REPLACE TEMP TABLE lake_file_inventory AS',1)
 || $sql$
SELECT CASE WHEN count(name)=1 AND bool_and(run_id::VARCHAR<>getvariable('lake_file_run_id'))
 THEN 'original owner retained' ELSE error('lock owner overwritten') END
 FROM agent.lake_capture_lock WHERE name='native-file-capture';
$sql$
 FROM read_text(getenv('CATALOG_SOURCE_ROOT') || '/server/lake_file_capture.sql')
) TO (getvariable('file_test_lock_program')) (FORMAT csv,HEADER false,QUOTE '',ESCAPE '');
SELECT CASE WHEN contains(content,'native file capture already owned')
 AND contains(content,'original owner retained') THEN 'second claimant rejected; original lock retained'
 ELSE error(content) END AS lock_result
 FROM read_text('/opt/homebrew/bin/duckdb :memory: -csv -noheader -f '
 || getvariable('file_test_lock_program') || ' 2>&1; true |');

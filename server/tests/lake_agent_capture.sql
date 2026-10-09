-- Run from repo root: /opt/homebrew/bin/duckdb :memory: -f server/tests/lake_agent_capture.sql
-- Executes the production reader/write templates against synthetic native rows in
-- an isolated in-memory DuckLake catalog. Only temporary /tmp test files are written.
LOAD shellfs;
SET VARIABLE lake_agent_test_root='/tmp/lake-agent-capture-test-' || uuid()::VARCHAR;
SET VARIABLE lake_agent_test_mkdir='mkdir -p "' || getvariable('lake_agent_test_root') || '" |';
FROM read_text(getvariable('lake_agent_test_mkdir'));
SET VARIABLE lake_agent_test_artifact=(SELECT content FROM read_text('server/lake_agent_capture.sql'));
SET VARIABLE lake_agent_test_reader=replace(replace(replace(
 string_split(getvariable('lake_agent_test_artifact'),'$reader$')[2],
 '@SYSTEM@','codex'),'@PATH@','synthetic'),
 '@PROJECTION@',
 'n.system,n.source,n.ordinal,n.byte_offset,n.line_number,n.input_tokens,'
 || 'CASE WHEN privacy_redacted AND n.uuid IS NOT NULL THEN ''[redacted: client-data boundary]'' ELSE n.uuid END AS uuid,'
 || 'CASE WHEN privacy_redacted AND n.timestamp IS NOT NULL THEN ''[redacted: client-data boundary]'' ELSE n.timestamp END AS timestamp,'
 || 'CASE WHEN privacy_redacted THEN ''[redacted: client-data boundary]'' ELSE n.message_content END AS message_content,'
 || 'CASE WHEN privacy_redacted THEN ''[redacted: client-data boundary]'' ELSE n.raw_event END AS raw_event,'
 || 'CASE WHEN privacy_redacted THEN ''[redacted: client-data boundary]'' ELSE n.metadata END AS metadata');
SET VARIABLE lake_agent_test_write=replace(replace(replace(replace(replace(replace(
 string_split(getvariable('lake_agent_test_artifact'),'$write$')[2],
 'FROM quack_query(''quack:127.0.0.1:19494'',$native$@READER@$native$,'
 || chr(10) || ' token := getenv(''QUACK_TOKEN''))',
 'FROM query($native$@READER@$native$)'),
 '@READER@',getvariable('lake_agent_test_reader')),'@RUN@','00000000-0000-0000-0000-000000000001'),
 '@SYSTEM@','codex'),'@HASH@','synthetic'),'@CURSOR@','');
SET VARIABLE lake_agent_test_prelude=$fixture$
LOAD ducklake;
ATTACH 'ducklake:duckdb::memory:' AS lake (DATA_PATH '@DATA@',DATA_INLINING_ROW_LIMIT 0);
CREATE SCHEMA lake.raw;
CREATE TABLE lake.raw.agent_capture_batches (
 run_id UUID,batch BIGINT,system VARCHAR,path_sha256 VARCHAR,source_rows BIGINT,
 inserted_rows BIGINT,privacy_redacted_rows BIGINT,completed_at TIMESTAMPTZ);
CREATE TABLE fixture AS
 SELECT 'native' AS source,'same-uuid' AS uuid,1::BIGINT AS ordinal,0::BIGINT AS byte_offset,
 1::BIGINT AS line_number,10::BIGINT AS input_tokens,NULL::VARCHAR AS timestamp,
 'clean' AS message_content,'{"ok":true}' AS raw_event,'{"parent":"retained"}' AS metadata
 UNION ALL SELECT 'native','same-uuid',2,100,2,10,NULL,'clean','{"ok":true}','{"parent":"retained"}'
 UNION ALL SELECT 'native','redacted-raw',3,200,3,20,NULL,'sensitive','{"policy_number":"secret-123"}','{"note":"secret-123"}'
 UNION ALL SELECT 'native','redacted-metadata',4,300,4,30,NULL,'sensitive','{"note":"secret-456"}','{"insured_name":"secret-456"}';
CREATE MACRO read_conversations(path:=NULL,source:=NULL,include_archived:=false) AS TABLE FROM fixture;
CREATE TABLE lake.raw.agent_observations AS
 SELECT *,NULL::UUID AS capture_run_id,NULL::TIMESTAMPTZ AS captured_at
 FROM query($empty$@READER@$empty$) WHERE false;
$fixture$;
SET VARIABLE lake_agent_test_tail=$assert$
SELECT CASE WHEN count(observation_fingerprint)=6 THEN true ELSE error('expected six physical/revised observations') END AS observations_ok
 FROM lake.raw.agent_observations;
SELECT CASE WHEN list(inserted_rows ORDER BY batch)=[4,0,1,1,0,0] THEN true
 ELSE error('capture rerun/revision/late/empty counts differ') END AS batches_ok
 FROM (SELECT batch,sum(inserted_rows) AS inserted_rows FROM lake.raw.agent_capture_batches GROUP BY batch);
SELECT CASE WHEN count(observation_fingerprint)=2 THEN true ELSE error('physical duplicate events were collapsed') END AS duplicates_ok
 FROM lake.raw.agent_observations WHERE uuid='same-uuid' AND raw_event='{"ok":true}';
SELECT CASE WHEN count(observation_fingerprint)=2 AND sum(input_tokens)=50
 THEN true ELSE error('redacted observations/tokens were lost') END AS redaction_ok
 FROM lake.raw.agent_observations WHERE privacy_redacted
 AND raw_event='[redacted: client-data boundary]' AND metadata='[redacted: client-data boundary]'
 AND message_content='[redacted: client-data boundary]';
SELECT CASE WHEN count(observation_fingerprint)=0 THEN true ELSE error('client data leaked through original fields') END AS privacy_ok
 FROM lake.raw.agent_observations WHERE contains(to_json(agent_observations)::VARCHAR,'secret-');
SELECT CASE WHEN count(observation_fingerprint)=4 THEN true ELSE error('null source timestamp observations were lost') END AS null_timestamp_ok
 FROM lake.raw.agent_observations WHERE timestamp IS NULL;
$assert$;
-- The final empty capture is valid and records a zero receipt; source deletion
-- never removes the archive. Original null timestamps are deliberately present.
COPY (SELECT replace(replace(getvariable('lake_agent_test_prelude'),'@DATA@',getvariable('lake_agent_test_root')||'/data'),
 '@READER@',getvariable('lake_agent_test_reader')) || chr(10)
 || replace(getvariable('lake_agent_test_write'),'@BATCH@','1') || chr(10)
 || replace(getvariable('lake_agent_test_write'),'@BATCH@','2') || chr(10)
 || 'UPDATE fixture SET raw_event=''revised'',timestamp=''1999-01-01'',input_tokens=11 WHERE ordinal=1;' || chr(10)
 || replace(getvariable('lake_agent_test_write'),'@BATCH@','3') || chr(10)
 || 'INSERT INTO fixture BY NAME SELECT ''native'' AS source,''late'' AS uuid,5 AS ordinal,400 AS byte_offset,5 AS line_number,40 AS input_tokens,''2000-01-01'' AS timestamp,''late'' AS message_content,''{}'' AS raw_event,''{}'' AS metadata;' || chr(10)
 || replace(getvariable('lake_agent_test_write'),'@BATCH@','4') || chr(10)
 || replace(getvariable('lake_agent_test_write'),'@BATCH@','6') || chr(10)
 || 'DELETE FROM fixture;' || chr(10)
 || replace(getvariable('lake_agent_test_write'),'@BATCH@','5') || chr(10)
 || getvariable('lake_agent_test_tail'))
TO (getvariable('lake_agent_test_root') || '/test.sql') (FORMAT csv,HEADER false,QUOTE '');
SET VARIABLE lake_agent_test_command='/opt/homebrew/bin/duckdb :memory: -csv -bail -f "'
 || getvariable('lake_agent_test_root') || '/test.sql" 2>&1 |';
FROM read_text(getvariable('lake_agent_test_command'));

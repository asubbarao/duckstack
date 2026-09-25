-- Disposable DuckLake proof for the catalog registration invariant. It uses an
-- in-memory metadata catalog and one unique /tmp Parquet file; no S3 or Postgres.
INSTALL ducklake; LOAD ducklake;
INSTALL scalarfs FROM community; LOAD scalarfs;
COPY (SELECT '/tmp/duckstack-lake-catalog-' || uuid()::VARCHAR || '.parquet')
TO 'variable:lake_catalog_fixture' (FORMAT variable, LIST none);
COPY (
  SELECT 'fixture-' || uuid()::VARCHAR AS publication_id, 'tester' AS producer,
         'test_result' AS kind, 'synthetic:catalog' AS source_ref,
         'v1' AS repo_revision, now() AS created_at,
         's3://duckstack-local/shared/fixture.parquet' AS local_uri,
         's3://inframe-duckstack-785081088852/raw/tester/fixture.parquet' AS remote_uri,
         'approved synthetic evidence' AS payload_text
) TO (getvariable('lake_catalog_fixture')) (FORMAT parquet);

ATTACH 'ducklake::memory:' AS local_catalog
  (DATA_PATH '/tmp/duckstack-lake-catalog-data/', DATA_INLINING_ROW_LIMIT 0);
CREATE TABLE local_catalog.agent_evidence AS
SELECT publication_id::VARCHAR AS publication_id, producer::VARCHAR AS producer,
       kind::VARCHAR AS kind, source_ref::VARCHAR AS source_ref,
       repo_revision::VARCHAR AS repo_revision, created_at::TIMESTAMPTZ AS created_at,
       local_uri::VARCHAR AS local_uri, remote_uri::VARCHAR AS remote_uri,
       payload_text::VARCHAR AS payload_text
FROM read_parquet(getvariable('lake_catalog_fixture'))
LIMIT 0;

CALL ducklake_add_data_files('local_catalog', 'agent_evidence',
                             getvariable('lake_catalog_fixture'));
CREATE TEMP TABLE lake_catalog_before_retry AS
SELECT count(publication_id) AS row_count, count(DISTINCT data_file) AS file_count
FROM local_catalog.agent_evidence,
     ducklake_list_files('local_catalog','agent_evidence');

-- This is the retry gate used by the scheduled worker: it sees the file in
-- metadata and does not invoke ducklake_add_data_files a second time.
SELECT CASE WHEN EXISTS (
  SELECT 1 FROM ducklake_list_files('local_catalog','agent_evidence')
  WHERE data_file=getvariable('lake_catalog_fixture')
) THEN 'already_registered' ELSE error('registration retry gate failed') END AS retry_outcome;

SELECT CASE WHEN row_count=1 AND file_count=1 THEN 'catalog registration passed'
            ELSE error('catalog registration duplicated a data file') END AS test_result
FROM lake_catalog_before_retry;

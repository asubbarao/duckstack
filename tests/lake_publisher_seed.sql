-- Explicit live synthetic fixture. Selected dev only; no credentials in results.
CREATE SCHEMA IF NOT EXISTS agents;
CREATE TABLE IF NOT EXISTS agents.lake_outbox (
 publication_id VARCHAR PRIMARY KEY, producer VARCHAR NOT NULL, kind VARCHAR NOT NULL,
 source_ref VARCHAR NOT NULL, repo_revision VARCHAR, created_at TIMESTAMPTZ NOT NULL,
 local_uri VARCHAR NOT NULL, remote_uri VARCHAR NOT NULL, sha256 VARCHAR NOT NULL,
 byte_size UBIGINT NOT NULL, status VARCHAR NOT NULL DEFAULT 'pending',
 attempts INTEGER NOT NULL DEFAULT 0, receipt JSON, last_error VARCHAR
);
COPY (SELECT password FROM read_csv('/usr/bin/security find-generic-password -w -s duckstack-minio-root-password -a duckstack |',
  header=false, delim=chr(31), quote='', columns={password:'VARCHAR'}))
TO 'variable:lake_fixture_password' (FORMAT variable, LIST none);
CREATE OR REPLACE SECRET minio_local (TYPE s3, KEY_ID 'duckstack', SECRET getvariable('lake_fixture_password'),
 REGION 'us-east-1', ENDPOINT '127.0.0.1:9100', URL_STYLE 'path', USE_SSL false, SCOPE 's3://duckstack-local/');
COPY (SELECT 'publisher-contract-' || uuid()::VARCHAR)
TO 'variable:lake_fixture_id' (FORMAT variable, LIST none);
COPY (SELECT 's3://duckstack-local/shared/' || getvariable('lake_fixture_id') || '.parquet')
TO 'variable:lake_fixture_uri' (FORMAT variable, LIST none);
-- 101 rows also exercise the bounded shared preview after publication.
COPY (SELECT getvariable('lake_fixture_id') AS publication_id, 'synthetic-publisher-proof' AS payload_text, 42 AS answer, row_id
      FROM range(101) t(row_id))
TO (getvariable('lake_fixture_uri')) (FORMAT parquet);
INSERT INTO agents.lake_outbox BY NAME
SELECT getvariable('lake_fixture_id') AS publication_id, 'alok' AS producer,
 'test_result' AS kind, 'synthetic:publisher-contract' AS source_ref, NULL::VARCHAR AS repo_revision,
 now() AS created_at, getvariable('lake_fixture_uri') AS local_uri,
 's3://inframe-duckstack-785081088852/raw/alok/' || publication_id || '.parquet' AS remote_uri,
 sha256(content) AS sha256, size AS byte_size FROM read_blob(getvariable('lake_fixture_uri'));
SELECT publication_id, sha256, byte_size, status FROM agents.lake_outbox
WHERE publication_id = getvariable('lake_fixture_id');

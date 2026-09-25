-- Explicit opt-in live smoke on selected dev, after lake_aws_credentials.sql.
-- Synthetic data only. Each run creates one unique object and manifest; no deletes.
COPY (SELECT 'shared-smoke-' || uuid()::VARCHAR)
TO 'variable:lake_fixture_id' (FORMAT variable, LIST none);
COPY (SELECT 's3://inframe-duckstack-785081088852/raw/alok/' || getvariable('lake_fixture_id') || '.parquet')
TO 'variable:lake_fixture_uri' (FORMAT variable, LIST none);
-- 101 rows exercise the shared preview's explicit truncation flag.
COPY (SELECT getvariable('lake_fixture_id') AS publication_id, 'synthetic-shared-read' AS event, 42 AS answer, row_id
      FROM range(101) t(row_id))
TO (getvariable('lake_fixture_uri')) (FORMAT parquet);
COPY (
  SELECT getvariable('lake_fixture_id') AS publication_id, 'alok' AS producer,
         getvariable('lake_fixture_uri') AS remote_uri,
         sha256(content) AS sha256, size AS byte_size
  FROM read_blob(getvariable('lake_fixture_uri'))
) TO ('s3://inframe-duckstack-785081088852/manifests/alok/' || getvariable('lake_fixture_id') || '.json')
(FORMAT json, ARRAY true);
SELECT getvariable('lake_fixture_id') AS publication_id, getvariable('lake_fixture_uri') AS remote_uri;

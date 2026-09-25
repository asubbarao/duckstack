-- Run with short-lived AWS credentials exported into this process environment.
-- Synthetic reference proof; each run creates one distinct S3 object.
INSTALL httpfs; LOAD httpfs;
INSTALL aws; LOAD aws;
CREATE TEMPORARY SECRET lake_smoke_aws (
  TYPE s3, PROVIDER credential_chain, CHAIN 'env', REGION 'us-west-2',
  SCOPE 's3://inframe-duckstack-785081088852/'
);
SET VARIABLE lake_smoke_uri = 's3://inframe-duckstack-785081088852/raw/alok/bootstrap/' || uuid()::VARCHAR || '.parquet';
COPY (SELECT 'duckdb-native-s3' AS event, 42::INTEGER AS answer)
TO (getvariable('lake_smoke_uri')) (FORMAT parquet);
SELECT CASE WHEN event = 'duckdb-native-s3' AND answer = 42 THEN true
            ELSE error('S3 read-back mismatch') END AS verified,
       getvariable('lake_smoke_uri') AS remote_uri
FROM read_parquet(getvariable('lake_smoke_uri'));

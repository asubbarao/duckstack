-- Creates request-scoped credentials for the shared DuckLake catalog.
-- The SSM tunnel must already listen on 127.0.0.1:15439. Neither the AWS
-- credential export nor the Secrets Manager value is selected or returned.
LOAD shellfs; LOAD scalarfs; LOAD httpfs; LOAD aws; LOAD postgres; LOAD ducklake;

CREATE TEMP TABLE lake_catalog_aws_credentials AS
FROM read_json('/opt/homebrew/bin/aws configure export-credentials --format process |');
COPY (SELECT AccessKeyId FROM lake_catalog_aws_credentials)
TO 'variable:lake_catalog_key_id' (FORMAT variable, LIST none);
COPY (SELECT SecretAccessKey FROM lake_catalog_aws_credentials)
TO 'variable:lake_catalog_secret_key' (FORMAT variable, LIST none);
COPY (SELECT SessionToken FROM lake_catalog_aws_credentials)
TO 'variable:lake_catalog_session_token' (FORMAT variable, LIST none);
CREATE OR REPLACE TEMPORARY SECRET lake_catalog_s3 (
  TYPE s3,
  KEY_ID getvariable('lake_catalog_key_id'),
  SECRET getvariable('lake_catalog_secret_key'),
  SESSION_TOKEN getvariable('lake_catalog_session_token'),
  REGION 'us-west-2',
  SCOPE 's3://inframe-duckstack-785081088852/'
);

COPY (
  SELECT password
  FROM read_csv(
    '/opt/homebrew/bin/aws secretsmanager get-secret-value --secret-id inframe/shared-dev/ducklake-catalog --region us-west-2 --query SecretString --output text |',
    header := false, delim := chr(31), quote := '', columns := {'password':'VARCHAR'},
    ignore_errors := false
  )
  WHERE nullif(password, '') IS NOT NULL
) TO 'variable:lake_catalog_password' (FORMAT variable, LIST none);

CREATE OR REPLACE TEMPORARY SECRET lake_catalog_postgres (
  TYPE postgres,
  HOST '127.0.0.1', PORT 15439,
  DATABASE 'duckstack_catalog', USER 'duckstack_writer',
  PASSWORD getvariable('lake_catalog_password')
);
CREATE OR REPLACE TEMPORARY SECRET lake_catalog_ducklake (
  TYPE ducklake,
  METADATA_PATH '',
  METADATA_PARAMETERS MAP {'TYPE':'postgres','SECRET':'lake_catalog_postgres'},
  DATA_PATH 's3://inframe-duckstack-785081088852/lake/data/'
);
DROP TABLE lake_catalog_aws_credentials;

-- `lake_catalog_ducklake` is the DuckLake secret used by the following attach.
-- It keeps the PostgreSQL password out of the ATTACH statement and result rows.
ATTACH 'ducklake:lake_catalog_ducklake' AS shared;
CREATE TABLE IF NOT EXISTS shared.agent_evidence (
  publication_id VARCHAR, producer VARCHAR, kind VARCHAR, source_ref VARCHAR,
  repo_revision VARCHAR, created_at TIMESTAMPTZ, local_uri VARCHAR,
  remote_uri VARCHAR, payload_text VARCHAR
);

-- Refresh only the developer-lake secret from the current AWS CLI login.
-- Credential values never become SQL literals or tool results.
LOAD shellfs; LOAD scalarfs; LOAD httpfs;
CREATE TEMP TABLE lake_credential_export AS
FROM read_json('/opt/homebrew/bin/aws configure export-credentials --format process |');
COPY (SELECT AccessKeyId FROM lake_credential_export)
TO 'variable:lake_key_id' (FORMAT variable, LIST none);
COPY (SELECT SecretAccessKey FROM lake_credential_export)
TO 'variable:lake_secret_key' (FORMAT variable, LIST none);
COPY (SELECT SessionToken FROM lake_credential_export)
TO 'variable:lake_session_token' (FORMAT variable, LIST none);
CREATE OR REPLACE SECRET developer_lake_aws (
    TYPE s3,
    KEY_ID getvariable('lake_key_id'),
    SECRET getvariable('lake_secret_key'),
    SESSION_TOKEN getvariable('lake_session_token'),
    REGION 'us-west-2',
    SCOPE 's3://inframe-duckstack-785081088852/'
);
DROP TABLE lake_credential_export;
-- Scalar variables disappear when this request connection closes.
SELECT name, type, scope FROM duckdb_secrets() WHERE name = 'developer_lake_aws';

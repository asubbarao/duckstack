-- Static contract checks for the SQL installer. This test reads source only and
-- does not execute ShellFS commands or contact the local MinIO service.
WITH source AS (
  SELECT content
  FROM read_text('server/lake_minio_install.sql')
),
installer AS (
  SELECT string_agg(content, chr(10)) AS sql_text
  FROM source
),
checks AS (
  SELECT 'configured loopback endpoints' AS check_name,
         position('127.0.0.1:9100' IN sql_text)>0
           AND position('127.0.0.1:9101' IN sql_text)>0 AS passed
  FROM installer
  UNION ALL
  SELECT 'named container and persistent data path',
         position('duckstack-minio' IN sql_text)>0
           AND position('$HOME/.duck/minio/data' IN sql_text)>0
  FROM installer
  UNION ALL
  SELECT 'Keychain credential flow',
         position('duckstack-minio-root-password' IN sql_text)>0
           AND position('variable:duckstack_minio_password' IN sql_text)>0
           AND position('SELECT password' IN sql_text)>0
  FROM installer
  UNION ALL
  SELECT 'versioned bucket and DuckDB round trip',
         position('duckstack-local' IN sql_text)>0
           AND position('version enable' IN sql_text)>0
           AND position('PARTITION_BY (probe_id)' IN sql_text)>0
           AND position('probe_id=' IN sql_text)>0
           AND position('COPY minio_smoke_expected' IN sql_text)>0
           AND position('read_parquet(' IN sql_text)>0
  FROM installer
  UNION ALL
  SELECT 'single SQL data path',
         position('.sh' IN lower(sql_text))=0
           AND position('.py' IN lower(sql_text))=0
           AND position('python3' IN lower(sql_text))=0
           AND position('set variable' IN lower(sql_text))=0
  FROM installer
  UNION ALL
  SELECT 'no destructive container replacement',
         position(' stop ' IN lower(sql_text))=0
           AND position(' rm ' IN lower(sql_text))=0
           AND position('--replace' IN lower(sql_text))=0
  FROM installer
)
SELECT check_name,
       CASE WHEN passed THEN 'pass'
            ELSE error('lake_minio_install contract failed: ' || check_name)
       END AS result
FROM checks
ORDER BY check_name;

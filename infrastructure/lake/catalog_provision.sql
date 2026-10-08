-- One-time, repeatable catalog provisioning from a laptop with an active SSM
-- tunnel to staging RDS on 127.0.0.1:15439. Run with duckdb :memory: -f this file.
-- Credentials stay in temporary DuckDB variables/secrets and are never selected.
-- This creates a separate developer database and login, never app tables.
LOAD shellfs;
LOAD scalarfs;
LOAD postgres;

CREATE TEMP TABLE staging_admin_credentials AS
FROM read_json('/opt/homebrew/bin/aws secretsmanager get-secret-value --secret-id inframe/staging/db-credentials --region us-west-2 --query SecretString --output text |');
COPY (SELECT username FROM staging_admin_credentials)
TO 'variable:catalog_admin_user' (FORMAT variable, LIST none);
COPY (SELECT password FROM staging_admin_credentials)
TO 'variable:catalog_admin_password' (FORMAT variable, LIST none);
DROP TABLE staging_admin_credentials;

COPY (SELECT password FROM read_csv(
  '/opt/homebrew/bin/aws secretsmanager get-secret-value --secret-id inframe/shared-dev/ducklake-catalog --region us-west-2 --query SecretString --output text |',
  header := false, delim := chr(31), quote := '', columns := {'password':'VARCHAR'})
  WHERE nullif(password, '') IS NOT NULL)
TO 'variable:catalog_writer_password' (FORMAT variable, LIST none);

CREATE SECRET staging_admin (
  TYPE postgres, HOST '127.0.0.1', PORT 15439, DATABASE 'postgres',
  USER getvariable('catalog_admin_user'),
  PASSWORD getvariable('catalog_admin_password'));
ATTACH '' AS staging_admin (TYPE postgres, SECRET staging_admin);

CALL postgres_execute('staging_admin', printf($pg$
  DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'duckstack_writer') THEN
      CREATE ROLE duckstack_writer LOGIN PASSWORD '%s';
    END IF;
  END $$;
$pg$, replace(getvariable('catalog_writer_password'), chr(39), chr(39)||chr(39))));

COPY (
  SELECT coalesce(bool_or(datname = 'duckstack_catalog'), false)
  FROM postgres_query('staging_admin', 'SELECT datname FROM pg_database')
) TO 'variable:catalog_database_exists' (FORMAT variable, LIST none);
CALL postgres_execute('staging_admin',
  CASE WHEN getvariable('catalog_database_exists') THEN 'SELECT 1'
       ELSE 'CREATE DATABASE duckstack_catalog OWNER duckstack_writer' END,
  use_transaction := false);
DETACH staging_admin;

CREATE SECRET catalog_writer (
  TYPE postgres, HOST '127.0.0.1', PORT 15439, DATABASE 'duckstack_catalog',
  USER 'duckstack_writer', PASSWORD getvariable('catalog_writer_password'));
ATTACH '' AS catalog_login (TYPE postgres, SECRET catalog_writer);
SELECT * FROM postgres_query('catalog_login', 'SELECT current_database() AS database_name, current_user AS login');

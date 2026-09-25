---
name: local-minio
description: >
  Bootstrap, prove, and use the loopback MinIO ingress for developer raw artifacts and
  Parquet. Use when a developer needs local object storage, asks to write logs or data through
  the S3 API, or is preparing immutable objects for promotion into the shared S3 DuckLake.
argument-hint: "[bootstrap | probe | publish]"
allowed-tools: Bash, mcp__dev__query, mcp__dev__sql
---

# Local MinIO ingress

Every developer has a private, loopback-only MinIO service. It is the working object store for
developer logs, raw captures, generated JSON, and Parquet—not a copy of staging or production.
The portable default is `http://127.0.0.1:9100`, console `http://127.0.0.1:9101`, container
`duckstack-minio`, data directory `~/.duck/minio/data`, and versioned bucket
`duckstack-local`.

## 1. Security boundary

Store the generated MinIO root password in the local OS keychain. Never commit it, print it,
place it in an MCP request, or put it in SQL literals. A local DuckDB client can create a
temporary secret from the process environment; the persistent dev service must receive the
same value only at startup and create its own scoped secret there.

Do not use `localhost:9000` by assumption: inspect the running container and use the declared
loopback endpoint. MinIO has no team data and no cloud credential.

## 2. Prove DuckDB, not just MinIO

The acceptance proof is a DuckDB `COPY` to a unique Parquet key, followed by `read_parquet`
of that exact key. A successful HTTP health endpoint, container start, or `mc` upload is not
enough.

```sql
INSTALL httpfs;
LOAD httpfs;
CREATE SECRET minio_local (
  TYPE S3,
  KEY_ID 'duckstack',
  SECRET getenv('MINIO_ROOT_PASSWORD'),
  REGION 'us-east-1',
  ENDPOINT '127.0.0.1:9100',
  URL_STYLE 'path',
  USE_SSL false
);
COPY (
  SELECT 'minio-parquet-smoke' AS event, now() AS recorded_at
) TO 's3://duckstack-local/bootstrap/minio-parquet-smoke.parquet' (FORMAT parquet);
FROM read_parquet('s3://duckstack-local/bootstrap/minio-parquet-smoke.parquet');
```

The password is supplied as a process environment variable by the local bootstrap, never typed
into the SQL body. Use a unique key for concurrent developers and retain the object version and
receipt in the local provenance row.

## 3. Promotion to the developer lake

Local MinIO is ingress, not the shared source of truth. A copier promotes only immutable,
provenance-bearing objects to a named team S3 prefix. Its idempotence key is the object content
hash plus producer and logical run id; an uncertain destination write is inspected before retry.

The shared DuckLake has a dedicated transactional Postgres catalog and S3 `DATA_PATH`, with
`DATA_INLINING_ROW_LIMIT 0` so small inserts actually create shared Parquet. Do not attach a
local DuckLake catalog as if it coordinated the team, and do not copy raw customer documents to
a broadly shared prefix.

---
name: s3-explore
description: >
  Explore and query data on S3, Cloudflare R2, GCS, MinIO, or any S3-compatible storage.
  Use when the user mentions an s3://, r2://, gs://, or gcs:// URL, asks "what's in this bucket",
  wants to list remote files, preview remote Parquet/CSV/JSON, or query data on object storage
  without downloading it. Also triggers when the user wants to know the size, schema, or row count
  of remote datasets.
argument-hint: <s3-url> [question about the data]
allowed-tools: Bash
---

You are helping the user explore data on remote object storage using DuckDB.

URL: `$0`
Question: `${1:-list and describe what's there}`

## Step 1 — Detect provider and set up credentials

Based on the URL or user context, prepend the appropriate secret configuration:

| Provider | URL patterns | Secret setup |
|---|---|---|
| **AWS S3** | `s3://` | `CREATE SECRET (TYPE S3, PROVIDER credential_chain);` |
| **Cloudflare R2** | `r2://`, `s3://` with R2 endpoint | `CREATE SECRET (TYPE R2, PROVIDER credential_chain);` |
| **GCS** | `gs://`, `gcs://` | `CREATE SECRET (TYPE GCS, PROVIDER credential_chain);` |
| **MinIO / custom** | `s3://` with custom endpoint | `CREATE SECRET (TYPE S3, KEY_ID '...', SECRET '...', ENDPOINT '...', USE_SSL true);` |

For R2, if the user provides an account ID, the endpoint is `<account_id>.r2.cloudflarestorage.com`. R2 URLs like `r2://bucket/path` should be rewritten to `s3://bucket/path` with the R2 secret.

For public buckets (e.g., Overture Maps, AWS open data), no secret is needed — skip this step.

Always prepend:
```sql
LOAD httpfs;
```

## Step 2 — Determine what the URL points to

If the URL looks like a **directory or bucket** (no file extension, or ends with `/`), list its contents with sizes:

```bash
duckdb -c "
LOAD httpfs;
<SECRET_SETUP>
SELECT filename, (size / 1024 / 1024)::DECIMAL(10,1) AS size_mb, last_modified
FROM read_blob('<URL>/*')
ORDER BY filename
LIMIT 50;
"
```

Note: only select `filename`, `size`, `last_modified` — never select `content`, which would download the actual files.

If the URL points to a **specific file or glob pattern** (has a file extension or contains `*`), preview it:

```bash
duckdb -c "
LOAD httpfs;
<SECRET_SETUP>
DESCRIBE FROM '<URL>';
SELECT count(*) AS row_count FROM '<URL>';
FROM '<URL>' LIMIT 20;
"
```

For **Parquet files**, get row counts and sizes from metadata (no data download):

```bash
duckdb -c "
LOAD httpfs;
<SECRET_SETUP>
SELECT file_name,
       sum(row_group_num_rows) AS total_rows,
       (sum(row_group_compressed_bytes) / 1024 / 1024)::DECIMAL(10,1) AS compressed_mb
FROM parquet_metadata('<URL>')
GROUP BY file_name;
"
```

## Step 3 — Answer the question

Using the listing, schema, or sample data, answer:

`${1:-list and describe what's there}`

If the user asks an analytical question (e.g., "how many rows match X"), write and run the appropriate SQL query. DuckDB pushes predicates down into Parquet on S3, so filtering is efficient even on large remote datasets.

## Error handling

- **`duckdb: command not found`** → delegate to `/duckstack:install-duckdb`
- **Access denied / 403** → suggest the user check credentials: `aws configure`, environment variables, or provide explicit key/secret
- **Bucket not found / 404** → check the URL and region
- **Timeout on large listing** → suggest narrowing the glob pattern or adding a prefix

## Local S3 (MinIO / RustFS) — writing to it, verified 2026-09-28

A whole in-memory database goes to local S3 in a handful of statements; there is no copier to build.
Worked example: `platform/tools/duckstack/ci/export.sql` in inframe (`duckdb -f ci.sql -f export.sql`).

```sql
INSTALL httpfs; LOAD httpfs;
CREATE OR REPLACE SECRET local_s3 (TYPE s3, KEY_ID 'minioadmin', SECRET 'minioadmin', URL_STYLE 'path', USE_SSL false,
    ENDPOINT coalesce(nullif(getenv('S3_ENDPOINT'), ''), 'localhost:9000'));   -- getenv works inside CREATE SECRET
FROM read_text('curl -s -o /dev/null -w "%{http_code}" -X PUT --aws-sigv4 "aws:amz:us-east-1:s3" --user minioadmin:minioadmin http://localhost:9000/<bucket> |');
EXPORT DATABASE 's3://<bucket>/<prefix>' (FORMAT parquet);                    -- IMPORT DATABASE restores it
```

- httpfs cannot create a bucket; S3's own `PUT /<bucket>` does, signed by curl's `--aws-sigv4` through shellfs.
  200 = created, 409 = already there; both are fine.
- `EXPORT DATABASE` to `s3://` writes one Parquet file per table plus `schema.sql` and `load.sql`.
- MinIO's images no longer pull (docker.io 404, quay.io 401). RustFS (`docker.io/rustfs/rustfs`) is the drop-in:
  `podman run -d --name duckstack-s3 --user 0 -p 9100:9000 -e RUSTFS_ACCESS_KEY=minioadmin -e RUSTFS_SECRET_KEY=minioadmin -v duckstack-s3:/data docker.io/rustfs/rustfs:latest /data`.
  Without `--user 0` and a named volume it dies with "Permission denied (os error 13)" on `/data`.
  A bare 403 from `http://localhost:9100/` means it is up and wants credentials.
- The first `podman run` pulls the image and can outlast an MCP request; the container is still created. Read the
  state back (`podman ps -a`) before running it again.
- From the dev quack's ShellFS, `docker compose` cannot find podman's socket; call `podman` directly.

### Any destination: `COPY … TO '| command'` (shellfs write pipe), verified 2026-09-28

shellfs makes a leading `|` a write pipe, so `COPY` streams its output into any shell command: an upload,
`scp`, `ssh host 'cat > file'`, `gzip`, `aws`. No bucket secret, no temp file.

```sql
INSTALL shellfs FROM community; LOAD shellfs;
COPY (FROM runs) TO '| aws --endpoint-url http://localhost:9100 s3 cp - s3://duckstack/ci/runs.parquet' (FORMAT parquet);
```

- Verified: 1,000 rows piped to RustFS through `aws s3 cp -` read back as 1,000 rows with the same sum.
- `curl -T -` to S3 fails with 411 MissingContentLength: stdin has no length, and S3 PUT requires one.
  `aws s3 cp -` streams a multipart upload and needs none; that is the command to pipe into.
- `EXPORT DATABASE` writes several files, so it cannot target one pipe; use it with the httpfs secret above,
  and the pipe for a single `COPY`.

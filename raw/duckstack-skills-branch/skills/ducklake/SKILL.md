---
name: ducklake
description: >
  Landing raw pulls in a DuckLake so a re-pull is a snapshot instead of an overwrite. Use when
  attaching a lake, when an insert produces a lake with no parquet in it, when asked to
  backfill or re-pull a window, or when deciding where a raw table should live.
argument-hint: "[attach <catalog> <data-path> | snapshots | probe]"
allowed-tools: Bash
---

DuckLake is DuckDB Labs' lakehouse format — `duckdb_extensions().installed_from = 'core'`, not
a community extension. Judge it accordingly; adoption metrics are the only signal a community
extension offers and they say nothing useful here. Verified locally 2026-09-17: a catalog with
a **local** data path works end to end — create, insert, `snapshots()`, `AT (VERSION => n)`.
Only the `s3://` path is unproven, and for a reason that has nothing to do with DuckLake.

## 1. Why this rather than a plain table

Every INSERT into a DuckLake is a **snapshot**. That is the entire reason to use it as the
landing layer for raw pulls: re-running the same window does not destroy the previous version,
so a backfill is auditable and a bad pull is recoverable rather than a lost afternoon. A plain
`CREATE OR REPLACE TABLE` gives you the opposite — the last writer wins and the evidence is gone.

## 2. Attach

A DuckLake is two things: a metadata catalog and a data path. The catalog can be a `.duckdb`
file, or postgres/sqlite when several processes share it. The data path is where the parquet
actually lands.

```sql
LOAD ducklake;
-- ATTACH 'ducklake:<metadata catalog>' AS <alias> (DATA_PATH '<directory or prefix>')
--   a LOCAL data path needs no secret and is how to prove the shape before involving S3
ATTACH 'ducklake:<...>/meta.ducklake' AS lake (DATA_PATH '<...>/lake/data/');
```

## 3. The failure that produces no error

`DATA_INLINING_ROW_LIMIT` does **not** default to 0. Small inserts stay inlined in the metadata
database and never become parquet files. You get a lake that queries correctly, reports rows,
and has nothing under its data path — no error, no warning. Against a local path this is merely
confusing. Against `s3://` it means the data never left the machine.

Set it to 0 whenever the point is files on disk or in object storage:

```sql
ATTACH 'ducklake:<...>' AS lake (DATA_PATH 's3://bucket/prefix/', DATA_INLINING_ROW_LIMIT 0);
```

## 4. Time travel, and dedupe as a view

```sql
SELECT snapshot_id, snapshot_time, changes FROM lake.snapshots() ORDER BY snapshot_id DESC;
SELECT count(*) FROM lake.<table> AT (VERSION => 1);
SELECT count(*) FROM lake.<table> AT (TIMESTAMP => now() - INTERVAL 1 HOUR);
```

**Never DELETE in the raw layer to deduplicate.** The raw layer's job is to be the record of
what the source returned; deleting from it destroys exactly the history the snapshots exist to
keep. Deduplication is a view on top, so the raw rows stay and the current view is derived:

```sql
CREATE OR REPLACE VIEW lake.<table> AS
SELECT * EXCLUDE (rn) FROM (
  SELECT *, row_number() OVER (PARTITION BY <key> ORDER BY pulled_at DESC) AS rn
  FROM lake.raw_<table>
) WHERE rn = 1;
```

Housekeeping is explicit and belongs in a maintenance window, not in a refresh:
`CALL lake.ducklake_expire_snapshots(older_than => now() - INTERVAL 90 DAY);`

## 5. The S3 blocker, stated plainly

`httpfs` and `aws` are both loaded on the server, so the *filesystem* is there. But
`duckdb_secrets()` on the server returns **zero rows** — there are no credentials of any kind.
An `s3://` data path therefore fails at the first data read, not at `ATTACH`, which reads as a
DuckLake problem and is not one.

Credentials are a server concern: they belong in the server's own setup as a secret, never in a
client `SET`, never as a literal. Endpoints, regions and URL styles are secrets here too, not
settings. Until one exists, prove everything against a local data path.

## 6. Report

State whether the data path was local or remote, whether `DATA_INLINING_ROW_LIMIT` was set, and
the snapshot id the write produced. "It inserted fine" is not a result when the parquet may not
exist — check the data path.

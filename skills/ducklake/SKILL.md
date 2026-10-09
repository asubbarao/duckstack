---
name: ducklake
description: Use the local DuckStack DuckLake, preserve original observations, publish checked SQL partitions, and inspect history without another writable copy.
---

# Local DuckLake

Use the selected dev MCP (9496), its existing JSON `/sql` endpoint (9495), or
`quack_query` against `quack:localhost:9494`. Never start another service or open
the live catalog for writing from a second local process.

`server/lake.sql`, read by `server/setup.sql`, attaches:

- Catalog: `~/.duck/lake/duckstack/catalog.ducklake`
- Parquet storage: `~/.duck/lake/duckstack/data/`
- Name: `lake`; `DATA_INLINING_ROW_LIMIT 0` ensures small writes also use Parquet.

This uses DuckDB Labs' `ducklake` extension. Plain Parquet directories, including
older helpers named `to_lake`, are not DuckLake catalogs.

## One owner per dataset

`lake.agent.stream`, `lake.agents.ext_*`, `lake.main.hostfs_folders`, and
`lake.main.agent_sql_guide` own their rows. The original dev names are read-only
compatibility views. Write to the qualified lake target. Never replace a view with
another writable table. Existing readers and local search indexes keep their names.
FTS, vectors, process snapshots and dispatch caches remain rebuildable working state.

`server/lake_agent_capture.sql` reads native `read_conversations()` records from
the existing reader on 19494. It preserves native types, raw events, metadata,
token counts, physical duplicates and revised observations. Original fingerprints
are computed before client-data redaction. Ingestion time is separate from source
event time; late or NULL timestamps do not fall behind a timestamp watermark.
Exact rereads are anti-joined rather than appended again.

Claude's native reader scans its full root (about 1.94 GB in the October 8
baseline), so the current capture excludes Claude until the reader can batch files.
Codex capture reads at most one JSONL of 32 MiB per invocation. File cursors use
size/mtime and reconcile daily. Archive capture is manual; no archive cron job is
registered. `dev.agent.lake_capture_lock` enforces one capture owner. Failure leaves
the lock and a DuckLake attempt receipt; inspect the exact run before clearing it.

`server/lake_snapshot.sql` retains typed, source-specific daily observations in
`lake.history`. Reruns replace today's partition transactionally, checking exact
row parity before commit. A success receipt records empty captures too. The date
is an observation date, not a business-effective date; a new capture cannot invent
an earlier day's data.

## Checked derived tables

The existing factory accepts `catalog="lake"` on
`DuckDBCreateTableWithSchemaOperator`. Executors stay independent of pipelines;
PostgreSQL callers keep their executor and dialect. Catalog-aware Dagster keys
distinguish identical schema/table names in different catalogs. Inline SQL and
`.DQCheck(...)` stay with the pipeline; implementation stays in the factory.

The factory stages typed rows, evaluates checks and publishes transactionally.
Failed checks preserve the previous partition. Empty successful partitions are
valid. Backfills use the same operator SQL with an explicit partition key.
Do not infer execution success merely from rows existing.

## Inspect

```sql
SELECT database_name,type,path FROM duckdb_databases() WHERE database_name='lake';
SELECT snapshot_id,snapshot_time,changes FROM lake.snapshots()
ORDER BY snapshot_id DESC LIMIT 7;
SELECT system,count(record_id) AS records
FROM lake.raw.agent_observations GROUP BY system;
SELECT * FROM lake.ops.state_captures ORDER BY captured_at DESC LIMIT 7;
-- Substitute an actual snapshot ID returned above:
SELECT id,ts,message_role FROM lake.agent.stream AT (VERSION => 12) LIMIT 4;
```

DuckLake versions record committed lake state; they do not replace business-effective
timestamps or observation dates. CTAS inside DuckLake preserves prior snapshots.
No automatic snapshot expiration or file cleanup is enabled by this integration.

## Isolation and eventual publication

Business-profile's PostgreSQL source and restricted copies stay isolated. Do not
import them here; their deletion deadline also applies to derived copies. Scratch
tables and unrelated legacy lakes are not silently imported.

Remote publication is a later explicit operation. Preserve a consistent catalog
backup plus all referenced data/delete files, and verify restored snapshots at the
destination. Parquet files alone are not a lake backup. See DuckLake's
[backup guide](https://ducklake.select/docs/stable/duckdb/guides/backups_and_recovery)
and [time travel](https://ducklake.select/docs/stable/duckdb/usage/time_travel).
Report the actual catalog, data path, snapshot and physical files. Do not claim
remote storage, credentials or backups were tested unless they were exercised.

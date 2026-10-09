---
name: ducklake
description: Use the local DuckStack DuckLake, preserve original observations, publish checked SQL partitions, and inspect history without another writable copy.
---

# Local DuckLake

Use the selected dev MCP (9495 `/mcp/`), its existing JSON `/sql` endpoint (9495), or
`quack_query` against `quack:localhost:9494`. Never start another service or open
the live catalog for writing from a second local process.

`server/setup.sql` attaches:

- Catalog: `~/.duck/lake/duckstack/catalog.ducklake`
- Parquet storage: `~/.duck/lake/duckstack/data/`
- Name: `lake`; `DATA_INLINING_ROW_LIMIT 0` ensures small writes also use Parquet.

This uses DuckDB Labs' `ducklake` extension. Plain Parquet directories, including
older helpers named `to_lake`, are not DuckLake catalogs.

## One owner per dataset

`lake.agents.ext_fetch` (raw docs pages) and `lake.main.agent_sql_guide` own their rows;
the `agents.ext_*` views on dev derive from them. Write to the qualified lake target.
FTS, vectors and process snapshots remain rebuildable working state.

Agent conversations are not copied into the lake: `agent.stream` on dev reads
agent_data's `read_conversations()` live (see `/duckstack:agent-stream`).

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

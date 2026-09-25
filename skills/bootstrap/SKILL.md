---
name: bootstrap
description: Find the common DuckStack workflows and join the shared developer lake from a laptop. Use when starting CI analysis, saving local evidence, rendering a Tera page, self-dispatching SQL, or reading shared DuckLake tables.
---

# Bootstrap the developer DuckStack

Start with the local `capabilities` MCP tool and `/duckstack:duckstack-core`.
Use only capabilities reported by this machine. The portable workflows live in
`/duckstack:duck-tails` and `/duckstack:duck-hunt` for CI evidence,
`/duckstack:tera` for rendered pages, and `/duckstack:self-dispatch` for row-driven
SQL. The InFrame repository's `platform/tools/duckstack/ci/ci.sql` is the canonical
GitHub Actions relations file.

For a finding worth retaining, follow `/duckstack:local-minio` and record a
small approved artifact with the local `lake_record` MCP tool. `lake_status`
shows its local and shared states. Local recording succeeds without AWS or a
catalog connection; retain the returned publication ID. A local drop is not
automatically eligible for S3. Follow `/duckstack:lake-publish` only when that
specific finding should join the collective. Do not send secrets, customer
documents, full conversations, or arbitrary raw logs to the shared bucket.

The shared bucket is `s3://inframe-duckstack-785081088852/`. Its DuckLake
metadata lives in the dedicated `duckstack_catalog` PostgreSQL database reached
through the staging bastion. The catalog is for developer data only. The local
publisher copies immutable MinIO objects to S3; a separate catalog step makes
verified objects visible in `agent_evidence`. See `server/LAKE.md` for the current
connection and acceptance commands. A local Postgres clone has its own catalog;
it does not merge metadata with the shared one.

Avoid designing project-specific bucket folders up front. Immutable object keys
are producer plus publication ID; `producer`, `kind`, `source_ref`, and revision
are table columns. That lets each agent drop evidence independently while one
shared logical table supplies the organization later.

DuckLake takes ownership of files registered with `ducklake_add_data_files`.
Keep the shared `raw/` objects and their manifests immutable; do not run
DuckLake compaction, snapshot expiration, or file cleanup on this imported table
without a migration plan for those source objects.

On reconnect, check `lake_status`, explicitly mark chosen IDs for sharing,
publish them through `lake_publish`, then run `lake_register`. Confirm each
published ID appears in the shared DuckLake from a fresh DuckDB process.
Repeated registration must leave one logical row and must not rewrite S3.

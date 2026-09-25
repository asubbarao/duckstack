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

For evidence you intend to share, follow `/duckstack:local-minio` and record a
small approved artifact with the local `lake_record` MCP tool. `lake_status`
shows whether it is pending, publishing, published, or needs attention. Local
recording succeeds without AWS or a catalog connection; retain the returned
publication ID. Do not send secrets, customer documents, full conversations, or
arbitrary raw logs to the shared bucket.

The shared bucket is `s3://inframe-duckstack-785081088852/`. Its DuckLake
metadata lives in the dedicated `duckstack_catalog` PostgreSQL database reached
through the staging bastion. The catalog is for developer data only. The local
publisher copies immutable MinIO objects to S3; a separate catalog step makes
verified objects visible in `agent_evidence`. See `server/LAKE.md` for the current
connection and acceptance commands. A local Postgres clone has its own catalog;
it does not merge metadata with the shared one.

DuckLake takes ownership of files registered with `ducklake_add_data_files`.
Keep the shared `raw/` objects and their manifests immutable; do not run
DuckLake compaction, snapshot expiration, or file cleanup on this imported table
without a migration plan for those source objects.

On reconnect, check `lake_status`, publish pending objects through `lake_publish`,
then run the catalog registration step. Confirm the published ID appears in the
shared DuckLake from a fresh DuckDB process. Repeated registration must leave one
logical row and must not rewrite the S3 object.

---
name: duckstack-core
description: >
  Discover and use the team-safe local DuckStack contract before relying on a local
  extension, MCP tool, S3 prefix, or DuckLake catalog. Use when bootstrapping a teammate,
  deciding whether a capability is core or personal-lab only, or publishing a shared artifact.
argument-hint: "[capabilities | shared-storage | publish]"
allowed-tools: Bash, mcp__dev__capabilities, mcp__dev__query, mcp__dev__sql
---

# DuckStack core

DuckStack is local-first. Every developer has a local DuckDB/Quack service and may have
personal-lab extensions. Do not assume one machine's experiments are installed or safe on
another machine. The common contract is what the local MCP reports through `capabilities`.

## 1. Discover before choosing

Call the `capabilities` MCP tool. It returns one row per declared capability and extension,
with the host's installed and loaded state. `core` is the portable team baseline; `shared`
means the extension is present but a separate, scoped storage configuration is still required.

Never infer that `installed` means a remote credential, a bucket, or a DuckLake catalog is
reachable. Never expose or select from secrets as a capability check.

## 2. The portable baseline

| capability | extensions | use |
|---|---|---|
| local_mcp | quack, quackapi, duckdb_mcp | local query and published MCP tools |
| source_evidence | duck_tails, duck_hunt, agent_data | revisioned source, CI, local agent evidence |
| document_local | pdf | deterministic text, tables, forms, geometry and OCR |
| row_dispatch | scalarfs, http_client | per-row work with raw receipts |
| rendered_artifacts | tera, quickjs | SQL-owned reports and previews |
| local_object_storage | httpfs | loopback MinIO raw/Parquet ingress, independently useful offline |

`lab` capabilities are useful only on the machine that advertises them. Promote one only by
adding it to this manifest, publishing an MCP primitive, and proving a representative smoke
test. A team member should never need to clone another developer's setup to run a core task.

## 3. Local MinIO, shared S3, and DuckLake

Each developer's MinIO is the local ingress for logs, raw captures, and Parquet. It is
loopback-only and independent of staging and production. Use `/duckstack:local-minio` to
prove a local DuckDB write and read-back before treating it as available.

The promotion path is deliberately one-way: local MinIO object + provenance manifest →
idempotent copier → named S3 prefix → shared DuckLake tables. MinIO is not a replica of
staging, and a local MinIO catalog is not the team catalog.

`shared_object_storage` and `shared_ducklake` are deliberately separate from core. They need:

1. a prefix-scoped S3 secret derived from the local AWS profile, SSO, or assumed role;
2. a named shared bucket and allowed prefix;
3. a transactional Postgres DuckLake catalog for concurrent writers; and
4. a representative Parquet write, read-back, snapshot, and unchanged rerun proof.

Use append-only, provenance-bearing rows for shared work: source identity, content hash,
producer, run id, timestamp, generated SQL, receipt, and error. A local run must remain useful
when shared storage is unavailable; promotion is a final idempotent stage, not an implicit
dependency.

Do not use an application production, staging, demo, or Terraform-state bucket/catalog as the
shared developer lake. Do not store raw customer documents in a broadly shared prefix.

## 4. Promotion gate

Promote a lab capability to core only when all are true:

- it has a stable MCP name and explicit read/write scope;
- a clean teammate machine reports it through `capabilities`;
- a real representative input produces inspectable rows/files/receipts;
- its test would fail if the behavior were removed; and
- shared writes have an idempotence key and an uncertain-write recovery path.

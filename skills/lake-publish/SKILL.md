---
name: lake-publish
description: Publish approved records from a developer's local MinIO outbox to the shared S3 developer lake and verify their DuckLake registration. Use when asked to share a recorded finding, CI result, or local evidence with the collective; do not use for automatic raw-log export.
---

# Give an approved drop to the collective

Start from a publication ID returned by `lake_record`, or inspect `lake_status`
for eligible local records. No local write requires this skill, and an offline
machine simply retains pending records. The shared destination is the developer
bucket `s3://inframe-duckstack-785081088852/`, not application staging/prod data.

1. Check the selected dev MCP and the exact local outbox row. Confirm the source,
   producer, approved payload, hash, and pending/failed status. Do not infer a
   producer from the OS username. Call `lake_request_share` for that exact ID;
   it only marks the local row eligible and makes no cloud call. Other previously
   approved IDs may share the next batch; `lake_publish` handles at most ten.
2. With a current AWS login, call `lake_publish` once. It conditionally creates
   immutable Parquet and manifest objects, reads their bytes back, and stores
   S3 version IDs in the local receipt. Inspect `lake_status` for the target ID.
   If the result is uncertain, reconcile the recorded receipt and remote object;
   never overwrite or replay an uncertain write by hand.
3. Call `lake_register` to reconcile already-published files with the shared
   DuckLake catalog. It verifies the S3 manifest and Parquet checksum before
   adding a file, and a retry checks catalog metadata first. Confirm the target
   ID is `registered` locally and visible in `shared.agent_evidence` from a fresh
   DuckDB connection. One ID should map to one logical row and one DuckLake file.

If AWS, the SSM catalog tunnel, or Secrets Manager is unavailable, stop after
the local receipt and report `pending` or `published-but-unregistered` accurately.
Do not make cloud access a prerequisite for `/duckstack:local-minio`. Do not
register an object directly by path without the manifest/integrity checks. Full
runbook and recovery details are in `server/LAKE.md`.

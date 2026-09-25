---
name: local-minio
description: Save developer CI/log data in local MinIO and record small approved findings in its sharing outbox. Use for local log tables, test results, review notes, or decisions; this skill never requires AWS or automatically publishes to S3.
---

# Drop evidence locally

The local MinIO bucket is a private outbox, not the team catalog. First use
`/duckstack:agent-door` to select this machine's dev MCP. If MinIO is not ready,
follow `server/LAKE.md` and its guarded `server/lake_minio_install.sql`; do not
replace a differently configured container or assume another Quack listener.

For larger local-only CI/log tables, DuckDB may `COPY` rows to a unique Parquet
key under `s3://duckstack-local/private/` and read that exact object back.
Keep provenance columns (source URL, revision, observed time, producer) in the
rows. These private files are not in the sharing outbox and never travel to S3
automatically. Use Duck Hunt for log parsing; do not put an entire log in an MCP
argument.

For a useful, explicitly approved finding, call `lake_record` with:

- `kind`: one of the kinds returned by the local `agents.lake_allowed_kinds` table
  (normally `build_result`, `test_result`, `review_note`, or `decision`);
- `source_ref`: a durable CI/GitHub URL or other exact source key;
- `repo_revision`: the verified commit SHA, or an empty string when inapplicable;
- `payload`: a concise, sanitized result (at most 4 KiB), not a raw log dump.

Retain the returned publication ID, local URI, SHA256, byte size, and status.
Read back that exact Parquet object through DuckDB and compare its ID/payload to
the result when the write matters; `lake_status` shows the durable outbox and any
interrupted claim. A missing or uncertain receipt is a reason to inspect, not to
blindly write a second object.

Do not put secrets, customer documents, full conversations, arbitrary queries,
or unsanitized CI logs into the shareable `lake_record` outbox. Local recording
does not publish to S3. When the user
wants the finding in the collective lake, continue with `/duckstack:lake-publish`.

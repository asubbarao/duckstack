---
name: ducklake
description: >
  Work with DuckLake catalogs through complete native System Quack SQL bodies. Use for lake
  attachment, snapshots, and storage diagnostics after inspecting current extension signatures.
argument-hint: "[attach <catalog> <data-path> | snapshots | probe]"
---

Read `/duckstack:duck` first. Use `duckdb.quack_query(sql)` for System Quack; it defaults to
`workspace`. The planned process may share a DuckLake attachment, but this source package is not
evidence that any lake, credentials, extension, or endpoint is currently available.

Inspect `duckdb_extensions()` and `duckdb_functions()` before using DuckLake syntax. Install/load
missing extensions through MCP when authorized, re-inspect their real signatures, and verify a
bounded call. A DuckLake `ATTACH` belongs inside a complete service body when explicitly required;
it is not a client `ATTACH` to System Quack.

Use an explicit catalog and data path. For object storage, inspect the configured secret/filesystem
capability before reads and preserve exact failures. Set `DATA_INLINING_ROW_LIMIT 0` only when
actual external Parquet objects are required. Keep snapshots and time-travel checks explicit and
report their catalog/path provenance. Do not recreate startup or add secrets just to make a
missing lake work.

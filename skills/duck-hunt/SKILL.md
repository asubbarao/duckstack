---
name: duck-hunt
description: >
  Parse build, test, lint, and CI logs as DuckDB relations, then land bounded results in System
  Quack through native MCP when requested.
argument-hint: "<log path | GitHub run> [format]"
---

Use a local ephemeral client only for the explicitly selected log input and after inspecting the
actual `duck_hunt` extension/function signature. Do not infer installed extensions from old
server notes. If System Quack needs the result, use native `duckdb.quack_query(sql)` with a
complete workspace body to create/insert the result relation.

Preserve run ID, job/unit, source location, raw message, parser format, severity, and status.
Distinguish parser false positives from real failures. Large parsed logs stay in `workspace` and
are queried with bounded slices/aggregates. Never attach the service database or use an old
sidecar to land results.

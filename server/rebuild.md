# Disposable dev endpoint (2026-10-02)

The database and WAL are outputs, not sources. An empty database uses setup.sql
alone: live.sql and the server definitions run immediately; cron.sql registers
the one-minute bounded agent loader and six-worker catalog fetches. No restore
step is part of startup. memory_limit is 8GB, before the configuration lock.

The canonical stream normalization is agent_stream_normalize.sql. Ingestion
groups native provider roots into 128 MiB batches, preserving original source
paths through temporary symlinks. Each generated SQL body finishes before the
next is submitted. Only an explicit reader connection failure before writes
may retry (up to three attempts); uncertain writes never retry.
Changed-file ingestion uses the same native reader and
normalization. Failed attempts are retained as failed on the next cycle.
Public conversations and subagent views read this cache. Text containing the
business-profile boundary or customer/insured/policy record keys is redacted
before it crosses from the native reader to dev; metadata and row counts remain.

Lasting source additions: agent.user_text from agent_user_text.sql (read by the
stream views job); agent.subagent_chats from agent_stream_views.sql;
agents.ext_doc_* and ext_catalog_documented from ../readthedocs_catalog.sql
(minute cron); meta.query_* and remote_queries from query_history.sql
(native log views, no separately attached history backup).

## Current entrypoints after cleanup

| Purpose | Retained source / interface |
|---|---|
| Conversation ingestion | `agent_stream_incremental.sql`, `agent_stream_normalize.sql`, and `agent_stream_views.sql`; scheduled by `agent_stream_schedule.sql`. |
| Open PR status | `open_prs.sql` builds `open_prs_waiting`; `duckdb_mcp.sql` publishes `ci_hunt` for native CI-log inspection. Broader run/job analysis uses `../skills/ci-timing/SKILL.md` and `../skills/duck-hunt/SKILL.md`. |
| Query timing and errors | `observability.sql` and `query_history.sql` expose native query records; `server_diagnostics.sql` retains native log-file and crash evidence. |
| Prometheus / Grafana | `observability.sql` serves `GET /metrics`; the existing Homebrew services own their configuration. |
| OTLP intake and reading | `quackapi.sql` retains received payloads; `telemetry.sql` resolves `pathmacro:telemetry?signal=logs`, `traces`, or `metrics`; `tests/telemetry.sql` exercises the intake/readers. |

The old full-refresh stream, isolated GitHub collector/templates, unused endpoint registry,
and unwired OTLP exporter/test have been removed from this folder.
The native query views are the retained query-monitoring interface. They do not generate
OTLP copies or provide the retired exporter's cursor/delivery ledger; that exporter was not
part of startup or a schedule. Original files and SHA-256 receipts are retained outside the
repository under `~/.duck/retired/server-cleanup-*/`.

The following previously restored tables are disposable session scratch and
are intentionally absent after an empty rebuild:

| Schema | Objects |
|---|---|
| agents | a1, a2, a3, a4, dataswarm_file, dataswarm_stdout, inf1433_test_audit_inventory |
| code_gardening_ci | events, jobs, log_fetch, run_fetch, steps |
| flock_config | FLOCKMTL_MODEL_USER_DEFINED_INTERNAL_TABLE, FLOCKMTL_PROMPT_INTERNAL_TABLE |
| main | agent_bank_case_files, agent_bank_case_receipts, agent_bank_case_sessions, agent_bank_catalog, agent_bank_edges, agent_bank_parent_rows, agent_bank_receipts, agent_bank_rows, agent_bank_sessions |
| main | agent_cost_lab_assets, agent_cost_lab_benchmarks, agent_cost_lab_checks, agent_cost_lab_rates |
| main | ci_jobs, jev_lab_metrics_fixture, jev_lab_source_fixture, jev_research_raw_20260929, raw_teague_fledgling_reading |
| semantic_layer | _definitions (empty; no semantic view retained) |
| main | prod_queries_01a0fb98_* (concurrent session diagnostics; no startup purpose) |

Their former demo/analysis SQL may be rerun separately, but none is server state.
Old sample/history rows in stream_refresh, host_process_samples,
server_instances and _setup_settings_history likewise have no preservation value.
The 47-table Parquet restore from the first audit is retired; the proof run uses
no backup.

Stop/start uses the existing launchd wrapper, whose TERM handler drains cron:
bootout gui/<uid>/com.inframe.quack, confirm 9494/9495 have no listener, remove
~/.duck/dev.duckdb (and its WAL if present), then bootstrap its existing plist.
Pause com.inframe.quack-reload while editing; bootstrap it again after proof.
Do not open the live database file from a second DuckDB process.

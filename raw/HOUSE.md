# HOUSE.md — the SQL rules, stated once

Every skill in this plugin and every file in `shelf/` follows these. When a skill and this file
disagree, this file wins and the skill is the bug. Each rule names the failure it prevents.
Source: ADR-002 (2026-09-17), which gathered them from the `duck` skill,
`inframe/internal/duckdb/README.md`, agent-stream `AGENTS.md`, pgedge-rag
`docs/techniques/*`, and closure `server/*.sql`.

## Where SQL runs

1. **Nobody opens a `.duckdb`.** Clients are `:memory:` and attach a quack. A lock error means
   the caller is wrong.
2. **Nothing is `LOAD`ed, `SET` or `INSTALL`ed against the shared server.** `SET` is refused
   by `lock_configuration`. `LOAD` is *not* refused (verified 2026-09-17) — it succeeds and
   changes the running server for every client until the next restart, which is exactly why
   it is not done. What a server needs goes in its setup file.
3. **Tokens are environment variables on the shell line**, read with `getenv()`; never a
   literal, never a file, never printed.
4. **`shellfs` only for real shell, only in a client.** Never on a server a quack client can
   reach: any client could then `read_csv('cmd |')`.

## Shape of a deliverable

5. **More than one statement = one `.sql` artifact:** header comment (what it braids, pinned
   revs, how to run) → `LOAD` lines → one table per statement, **raw first** → verification
   queries as comments at the bottom.
6. **Readers infer the schema.** Keep every row and column in base layers; no
   `json_extract`/regex on a raw string when a reader can type it.
7. **No summaries in base layers:** `array_agg(x) AS xs, len(xs) AS n`, not `count(*)`.
8. **Every function call carries a comment listing its parameters and defaults.**
9. **Views over materialization.** Materialize only what physics forces — history mirrors,
   ANN/BM25 indexes — and obey lock order (source before history, both directions) when you do.

## State and parameters

10. **No `SET VARIABLE`, `getvariable()`, `.read` orchestration.** Parameters are rows (a
    `runs` row); configuration a file needs comes from `getenv()` inline.
11. **State is an append-only log.** Pending = `units ANTI JOIN log`. A re-run costs only
    what the log lacks. No claim tables, no status columns.
12. **Failures are rows** (status, body, error). Never `WHERE raw IS NOT NULL` on a capture.
13. **One logical write = one transaction = one DuckLake snapshot**, signed with
    `ducklake_set_commit_message(catalog, author, message)`. Snapshots are the audit log;
    they are never expired.

## Per-row work (self-dispatch)

14. **Table functions bind literals; a column is refused** ("does not support lateral join
    column parameters"). Per-row work is self-dispatch — never a loop, a macro stage, Python
    or a shell script. Forms, all in `skills/self-dispatch` and `shelf/ext/quackapi*.sql`:
    a scalar `http_post[_form]` to a `query($q)` route on a loopback listener; a printed
    command list run by `bash` (process-per-row, for session-global work); the quack loopback.
15. **The posted body is one bare SELECT.** Extensions and secrets are preloaded.
16. **Re-align by ordinality:** `array_agg(… ORDER BY rn)` then `UNNEST … WITH ORDINALITY`.
    quackapi serves with `preserve_insertion_order = false`; without this, rows come back in
    any order (seen: reversed).
17. **Thread a `rep` into repeated bodies.** A macro over `http_post` is deterministic per
    argument tuple: five identical bodies are one call, duplicated.
18. **Lateral functions only correlated:** `FROM rel CROSS JOIN LATERAL f(rel.col)`.

## Files and the web

19. **Filesystem = `hostfs` typed scalars** (`file_extension`, `is_dir`, `file_size`). Never
    `glob`, `ls` through a shell, or `LIKE` on a path. List and filter first, read survivors.
20. **Crawl with `crawl_url` in a correlated LATERAL**; parse markup with `webbed` readers
    (`record_element :=`), not regex; `read_html` is registered twice — named parameters only.

## Claims

21. **A claim carries its evidence:** `-- @verified: <date> on <target>`. Unexercised is said
    out loud. A file whose `@rev` differs from `duckdb_extensions().extension_version` is due
    for a re-run.
22. **Provenance is not maturity.** `installed_from = 'core'` is DuckDB Labs' own work;
    `community` is whoever published it. Never rank one against the other by download counts.

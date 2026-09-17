---
name: self-dispatch
description: >
  Self-dispatch — the database writes the statement it cannot bind, then runs it. Use whenever a
  table function (glob, ls, lsr, read_text, read_csv, read_blob, crawl, quack_query, query) needs
  a value that lives in a column ("does not support lateral join column parameters"), whenever
  work must fan out per row, or whenever an agent is about to reach for SET VARIABLE, a macro, a
  loop, Python or a shell script to get around that wall. Three verified forms on this machine:
  in-process httpserver (the canonical one), the stock two-pipe form, and the quack loopback.
argument-hint: "[inprocess | pipe | quack] [what varies per row]"
allowed-tools: Bash
---

"Self-dispatch works. Every time. Agents never know how to use it." This skill is the how.

## The wall, stated exactly (verified DuckDB 1.5.5, 2026-09-17)

`glob()`, `ls()`, `lsr()`, `read_text()`, `read_csv()`, `read_blob()`, `crawl()`, `quack_query()`,
`dev.query()` are **table functions: their arguments bind at parse time** — a literal, `getenv()`,
`getvariable()`, or pure concatenation of those. A column is refused:

```
Binder Error: Table function "glob" does not support lateral join column parameters
```

A **scalar** function takes columns. `http_post_form(url, headers, params)` is a scalar. So:
build the statement you need *as a string, per row*, hand it to a scalar that runs SQL, read the
rows back. The database dispatches to itself. No `SET VARIABLE`, no macro, no loop, no script.

## Form 1 — in-process httpserver (canonical: one process, no server, no file)

The `:memory:` process starts its own loopback listener, posts to itself, stops it. Verified
verbatim with the real primitive — hostfs `ls(dir)`, whose path scalars (`is_file`,
`file_extension`, `file_size`, `file_last_modified`, `parse_path`) take columns and need no
dispatch (`INSTALL httpserver FROM community` once on the client):

```sql
LOAD httpserver; LOAD http_client; LOAD hostfs;
-- httpserve_start(host, port, auth) : auth '' = none; bind loopback only; the port is a parameter
SELECT httpserve_start('127.0.0.1', 19501, '') AS listener;

WITH dirs  AS (SELECT unnest(['/etc', '/usr/share/zoneinfo/America']) AS d),
-- the statement is TEXT built per row; a value that may contain a quote is doubled first
stmts AS (SELECT d, format('SELECT path FROM ls(''{}'')', replace(d, '''', '''''')) AS q FROM dirs),
-- the barrier: array_agg forces every POST to complete before any row below exists
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19501/', MAP{}, MAP{'q': q}) ORDER BY d) AS responses
          FROM stmts),
each  AS (SELECT u.idx, (u.r).status AS status, ((u.r).body ->> '$') AS ndjson
          FROM fired CROSS JOIN UNNEST(responses) WITH ORDINALITY AS u(r, idx)),
-- httpserver answers NDJSON, one line per result row, every value a string: parse by name, cast at read
lines AS (SELECT idx, status, unnest(string_split(ndjson, chr(10))) AS line FROM each),
paths AS (SELECT idx, status, line ->> '$.path' AS path FROM lines WHERE length(line) > 0)
-- the scalars ride on the returned column: no second dispatch for metadata
SELECT idx, status, len(list(path)) AS n,
       sum(file_size(path)) FILTER (WHERE is_file(path)) AS bytes,
       list(DISTINCT file_extension(path)) FILTER (WHERE is_file(path)) AS exts
FROM paths GROUP BY ALL ORDER BY idx;

SELECT httpserve_stop() AS stopped;
```

Result: `/etc 74 entries 808,420 bytes`, `…/America 147 entries`, both `status 200`. The
payload is *any* statement — a reader, `COPY … TO`, DDL, a multi-statement script — so a
heterogeneous fan-out is the same shape with a different `stmts` CTE. N rows fire N requests
that overlap across the process's threads (the reference repo measured 4×1 s ≈ 1.8 s).

**Why `ls` and not `glob`.** `glob('dir/*')` matches the *filesystem*; `ls`/`lsr` over a map
you already hold matches the *map* — policy-excluded junk cannot re-enter through a pattern,
and the typed scalars come with the row. `glob` is a probe ("is this directory empty"), not a
reader. The same holds for the read: `read_blob([explicit list])`, never `read_text('dir/*')`.

`status = -1` means nothing HTTP answered at that URL. Quack's port (`9494`) speaks the Quack
Remote Protocol, not HTTP — posting `q=` there is the mistake every agent makes. The executor
is *your own* `httpserve_start`, or a port you were explicitly given.

## Form 2 — stock duckdb, two constant pipes (no extension beyond shellfs, no file written)

For parallel *other binaries* (LLM CLIs, curl, osascript) or when a listener is not wanted.
Both pipe commands are constant text; what varies is data the inner generator reads:

```sql
LOAD shellfs;
-- read_csv('<cmd> |', ...) : the constant pipe IS the dispatch and the barrier — the scan
-- returns when the child exits. Inner duckdb emits one statement per row; outer duckdb runs them.
FROM read_csv($p$duckdb -csv -noheader -c "COPY (SELECT format('LOAD hostfs; SELECT ''{}'' AS dir, count(*) AS n FROM ls(''{}'');', d, d) AS stmt FROM read_csv('/path/dirs.csv', header := false, columns := {'d': 'VARCHAR'})) TO '/dev/stdout' (FORMAT csv, QUOTE '', HEADER false)" | duckdb -csv -noheader |$p$,
              header := false, columns := {'dir': 'VARCHAR', 'n': 'BIGINT'});
```

Verified (with `glob` as the stand-in; `ls` is the same shape). `closure/server/judge.sql` is this form with `| bash |` as the
executor: DuckDB prints one env-carrying command per LLM judge, the shell runs them with `&` and
`wait`, each writes its own vote file, the scan returns when `wait` does. The generated commands
are never written to a `.sh` — they go down the pipe.

## Form 3 — the quack loopback (server runs a whole body it built)

The dev server can call **itself**; its own token is in its environment:

```sql
FROM dev.query($$
  FROM quack_query('quack:localhost:9494', 'SELECT 42 AS self_dispatched', token := getenv('QUACK_TOKEN'))
$$);
```

Verified: `42`. This is a table function, so the inner SQL is literal / `getvariable` /
concatenation — the whole body, not per row. Use it when the body is one statement built from
constants and the result should stay on dev; use Form 1 when each row needs a different one.
The reference repos' `ATTACH … AS self` is the same thing with an alias; not needed here.

## Rules (from the reference repos, all of which do this)

1. **Statements are rows.** A `stmts` CTE with one column `q`. `format()` builds it; a value
   that might contain `'` is `replace(v, '''', '''''')` first. Never `||` chains.
2. **`array_agg` then `UNNEST … WITH ORDINALITY`** — the aggregate is the barrier, the
   ordinality is the order. No `LATERAL` keyword, no variables, no macros.
3. **Gate on `status`** before parsing; keep the failed rows with their body — an error is a
   row, not a missing row.
4. **The port is a parameter row, never a fact about the machine.** `agent-stream` runs Quack
   `:9494` + HTTPServer `:9496` + QuackAPI `:9497` in one process; the inframe duckstack runs
   the MCP sidecar on `:9496` and telemetry on `:9497` and **no httpserver at all** — the same
   `dispatch` macro is dead on one box and live on the other. `httpserve_start` your own.
5. **Loopback only.** `127.0.0.1`, no auth needed, stop it when done.
6. **Generated statement, not generated `.sh`.** If the executor is a shell, it is a pipe.
7. **Prefer no dispatch.** If a reader accepts an explicit list literal (`read_text(['a','b'])`,
   `read_blob([...])`), build that list from the map with `string_agg` as ONE statement and run
   it once — the llm-waves teardown design. Dispatch when the fan-out is truly per row.

## Reference artifacts (proposed from the review worktrees, both run as-is)

- `references/declarative_pipeline.sql` — Form 1 end to end in one process: `lsr` discovery →
  a `readers` **rows table** (extension → table function + full named args) joined on extension →
  one `format()` per file → fire → NDJSON rows → a second `read_lines` wave. Params are a row;
  failures are rows. Verified 11/11 files, 608 lines.
- `references/declarative_ls.sql` — the no-dispatch case: one `lsr(root, depth)`, prune by
  name, typed scalars. Verified 12 rows. (Its predecessor's `lsr(r.path, 1)` was the binder
  error.)

Origin: `~/reviews/agent-stream` branch `review/2026-09-17`, personal-recovery/sql/. The
originals are unchanged on `main`.

## Where it is written down (review worktrees)

- `~/reviews/agent-stream/personal-recovery/sql/declarative_ls.sql` writes `FROM roots r, lsr(r.path, 1)`
  — a **binder error** on 1.5.5 ("lsr does not support lateral join column parameters"). That
  file is the wall, not a way around it; `declarative_pipeline.sql` is the answer to it.
- `~/reviews/agent-stream/personal-recovery/sql/declarative_pipeline.sql` — Form 1 end to end:
  `lsr` discovery → per-extension reader statements → fire → NDJSON rows → a second wave of
  `read_lines` over what the readers touched.
- `~/reviews/duckdb-ops-toolkit/conduit/docs/self-dispatch*.md` — the why, the molecule, the
  executor matrix.
- `~/reviews/duckdb-llm-waves/sql/crawl.sql` — the nine-level frontier crawl (posts to `:9494`,
  which is quack here — see `dev.review_findings`).
- `~/reviews/closure/server/judge.sql` — Form 2 with `bash` as the executor.

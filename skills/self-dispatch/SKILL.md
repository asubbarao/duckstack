---
name: self-dispatch
description: >
  Self-dispatch — the database writes the statement it cannot bind, then runs it. Use whenever a
  table function (glob, ls, lsr, read_text, read_csv, read_blob, crawl, quack_query, query) needs
  a value that lives in a column ("does not support lateral join column parameters"), whenever
  work must fan out per row, or whenever an agent is about to reach for SET VARIABLE, a macro, a
  loop, Python or a shell script to get around that wall. On dev: two CTEs — statements → array_agg(http_post_form to /sql) → UNNEST
  — through the dev MCP `sql` tool or POST localhost:9498/sql. No macro. Other DuckDBs:
  quackapi in-process, the two-pipe form, or the quack loopback.
argument-hint: "[inprocess | pipe | quack] [what varies per row]"
allowed-tools: Bash
---

"Self-dispatch works. Every time. Agents never know how to use it." This skill is the how.

## On this machine: dev serves `/sql` — the molecule is two CTEs, no macro

Dev runs quackapi in its own process; `POST /sql` runs any SQL (DDL, DML, several statements).
Self-dispatch is **not** a function you call per row. It is two CTEs: `statements` builds one
statement per row from real data; `dispatched` posts them all in one `array_agg` (the barrier)
and the outer query `UNNEST`s the responses. One statement or ten thousand, same shape.
No `VALUES`, no macro, no `SET VARIABLE`, no nested quotes — `chr(39)` is the quote.

```sql
WITH statements AS (
  SELECT table_schema, table_name,
         'SELECT ' || chr(39) || table_schema || '.' || table_name || chr(39) || ' AS table_ref, '
         || 'len(array_agg(column_name)) AS column_count FROM information_schema.columns '
         || 'WHERE table_schema = ' || chr(39) || table_schema || chr(39)
         || ' AND table_name = ' || chr(39) || table_name || chr(39) AS statement
  FROM information_schema.tables
  WHERE table_schema = 'main'
  ORDER BY table_name
  LIMIT 5
),
dispatched AS (
  SELECT array_agg(http_post_form(listen_url || '/sql', MAP {}, MAP {'sql': statement})
                   ORDER BY table_name) AS responses
  FROM statements, quackapi_servers()
)
SELECT response ->> 'status' AS status,
       response_row ->> 'table_ref' AS table_ref,
       (response_row ->> 'column_count')::BIGINT AS column_count
FROM dispatched,
     UNNEST(responses) AS dispatched_responses(response),
     UNNEST(from_json(response ->> 'body', '["JSON"]')) AS body_rows(response_row)
ORDER BY table_ref;
```

`quackapi_servers()` returns the URL of the server this query is running in, so nothing is
hardcoded. Widen the `LIMIT`, swap the `statements` CTE for whatever varies per row.

Run it any of these ways — they are the same door:

- the `dev` MCP's `sql` tool;
- `curl -s -X POST localhost:9498/sql --data-urlencode 'sql@file.sql'`;
- `http_post_form('http://localhost:9498/sql', MAP {}, MAP {'sql': …})` from a `:memory:` DuckDB.

Verified 2026-09-21 on live dev: 5 tables → 5 statements → 5 responses, status 200, typed
columns back. The reference pipelines are `~/personal/self-dispatch/sql/*.sql` and
`asubbarao/agent-stream/personal-recovery/sql/`. The forms below are for a DuckDB that is not dev.

## The wall, stated exactly (verified DuckDB 1.5.5, 2026-09-17)

`glob()`, `ls()`, `lsr()`, `read_text()`, `read_csv()`, `read_blob()`, `crawl()`, `quack_query()`,
`quack_query()` are **table functions: their arguments bind at parse time** — a literal, `getenv()`,
`getvariable()`, or pure concatenation of those. A column is refused:

```
Binder Error: Table function "glob" does not support lateral join column parameters
```

A **scalar** function takes columns. `http_post_form(url, headers, params)` is a scalar. So:
build the statement you need *as a string, per row*, hand it to a scalar that runs SQL, read the
rows back. The database dispatches to itself. No `SET VARIABLE`, no macro, no loop, no script.

## Form 1 — quackapi in-process (canonical: one process, one route, no server, no file)

`quackapi` is the user's own extension (`CREATE ROUTE` turns SQL into a typed HTTP endpoint;
`quackapi_serve` serves it from this process). The executor is **one route whose handler is
`query($q)`**. Verified verbatim (`INSTALL quackapi FROM community` once on the client):

```sql
LOAD hostfs; LOAD http_client; LOAD quackapi;
-- the executor: one route, one handler, any statement; a JSON array of typed rows comes back
CREATE OR REPLACE ROUTE dispatch POST '/q' AS SELECT rows.* FROM query($q) rows;
-- quackapi_serve(port, host := ...) returns at once; loopback only
FROM quackapi_serve(19502, host := '127.0.0.1');

WITH roots AS (SELECT path FROM ls('/some/root') WHERE is_dir(path)),
-- the statement is TEXT built per row; chr(39) is the quote — no doubled-quote soup
stmts AS (SELECT path AS root, format('SELECT path FROM lsr({}{}{}, 1)', chr(39), path, chr(39)) AS q FROM roots),
-- the barrier: array_agg forces every POST to complete before any row below exists
fired AS (SELECT array_agg(struct_pack(root := root,
                                       r := http_post_form('http://127.0.0.1:19502/q', MAP{}, MAP{'q': q}))
                           ORDER BY root) AS responses FROM stmts),
-- a JSON array of row objects back: unnest it, read by name, types follow the columns
wave1 AS (SELECT (u.e).root AS root, ((u.e).r).status AS status, row.path AS path
          FROM fired CROSS JOIN UNNEST(responses) WITH ORDINALITY AS u(e, idx),
               unnest(from_json((((u.e).r).body ->> '$'), '[{"path":"VARCHAR"}]')) AS s(row))
SELECT root, status, path, is_file(path) AS is_file, file_size(path) AS file_size
FROM wave1 ORDER BY path;

FROM quackapi_stop();
```

Result: one `lsr` per root row, `status 200`, typed rows. The payload is *any* statement —
a reader, `COPY … TO`, DDL — so a heterogeneous fan-out is the same shape with a different
`stmts` CTE. Route params bind from path, query, JSON body and form alike (`$q` here is the
form field); a fixed-shape handler can instead declare `PARAM`s and a `STATUS`.

**Why `ls` and not `glob`.** `glob('dir/*')` matches the *filesystem*; `ls`/`lsr` over a map
you already hold matches the *map* — policy-excluded junk cannot re-enter through a pattern,
and the typed scalars come with the row. The same holds for the read: `read_blob([explicit
list])`, never `read_text('dir/*')`.

`status = -1` means nothing HTTP answered at that URL. Quack's port (`9494`) speaks the Quack
Remote Protocol, not HTTP — posting `q=` there is the mistake every agent makes. The executor
is *your own* route, or a port you were explicitly given. (`httpserver`'s `httpserve_start`
is the generic-form-executor variant the reference repos also use; quackapi is the one to
reach for here.)

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
   `dispatch` macro is dead on one box and live on the other. serve your own route.
5. **Loopback only.** `127.0.0.1`, no auth needed, stop it when done.
6. **Generated statement, not generated `.sh`.** If the executor is a shell, it is a pipe.
7. **Prefer no dispatch.** If a reader accepts an explicit list literal (`read_text(['a','b'])`,
   `read_blob([...])`), build that list from the map with `string_agg` as ONE statement and run
   it once — the llm-waves teardown design. Dispatch when the fan-out is truly per row.

## Reference artifacts (proposed from the review worktrees, both run as-is)

- `references/declarative_pipeline.sql` — Form 1 end to end in one process (quackapi route): `lsr` discovery →
  a `readers` **rows table** (extension → table function + full named args) joined on extension →
  one `format()` per file → fire → NDJSON rows → a second `read_lines` wave. Params are a row;
  failures are rows. Verified 11/11 files, 608 lines.
- `references/declarative_ls.sql` — the shape as written (`roots` → one `lsr(child, 1)` per
  row), kept exactly, with the per-row call self-dispatched through the quackapi route. Verified 11 rows. The binder error
  is not a constraint; it is the cue.

- `references/frontier_crawl.sql` — the level-by-level directory crawl (llm-waves): prune by
  name BEFORE descending, one `ls` per frontier row through the route, nine unrolled levels
  (no `WITH RECURSIVE`), no macros. Verified 3 folders / 11 files / 0 leaks on its own repo.

Origin: review branches `review/2026-09-17` under `~/reviews/`. The originals are unchanged
on each repo's `main`.

## Where it is written down (review worktrees)

- `~/reviews/agent-stream/personal-recovery/sql/declarative_pipeline.sql` — Form 1 end to end:
  `lsr` discovery → per-extension reader statements → fire → NDJSON rows → a second wave of
  `read_lines` over what the readers touched.
- `~/reviews/duckdb-ops-toolkit/conduit/docs/self-dispatch*.md` — the why, the molecule, the
  executor matrix.
- `~/reviews/duckdb-llm-waves/sql/crawl.sql` — the nine-level frontier crawl (posts to `:9494`,
  which is quack here — see `dev.review_findings`).
- `~/reviews/closure/server/judge.sql` — Form 2 with `bash` as the executor.

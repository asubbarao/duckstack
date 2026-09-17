---
name: quack
description: >
  How to call the Quack server: quack_query, one complete body, no attach. Use before any
  statement that touches the server, when a table "does not exist", when a join fails with
  "Multiple streaming scans", or when reaching for ATTACH / .read / SET VARIABLE to set up.
argument-hint: "[send <sql> | probe]"
allowed-tools: Bash
---

There is one way to call the server and it is a function call:

```bash
export QUACK_TOKEN="$(cat ~/.duck/token)"
```
```sql
LOAD quack;
-- quack_query(uri, sql, disable_ssl := false, token := ...) -> the server's result as rows
FROM quack_query('quack:localhost:9494', $$<one complete body>$$, token := getenv('QUACK_TOKEN'));
```

That is the whole interface. No `ATTACH`, no alias, no `dev.` prefix, no state file, nothing
to establish before it and nothing to re-establish after a restart.

## Why not ATTACH

`ATTACH` is client-side session state, and it is broken in two ways that waste the most time.
Both measured on this machine, 2026-09-17, same server, same moment.

**The server's tables are invisible.** The remote catalog is not mirrored, so the client's own
catalog views answer for a database that, as far as they are concerned, is empty:

```sql
-- through ATTACH
SELECT count(*) FROM duckdb_tables() WHERE database_name = 'dev';   -- 0
-- through quack_query
$$SELECT count(*) FROM duckdb_tables() WHERE NOT internal$$          -- 20
```

An agent lists tables, sees nothing, and concludes its write failed. The write was fine; it
asked the wrong process. This is the single most common false alarm on this stack.

**A join of two server tables fails outright.**

```sql
-- through ATTACH
SELECT count(*) FROM dev.raw_gh_runs_inframe r JOIN dev.raw_git_log_inframe g
  ON g.commit_hash = r.headSha;
-- Not implemented Error: Multiple streaming scans or streaming scans + CTAS / insert
-- in the same query are not currently supported

-- through quack_query, same join, inside the body
$$SELECT count(*) FROM raw_gh_runs_inframe r JOIN raw_git_log_inframe g
    ON g.commit_hash = r.headSha$$                                   -- 140
```

The attach turns each table into a streaming scan and DuckDB will not plan two of them
together. Every real query joins something, so this is not an edge case.

On top of those: an attach has to be re-issued after a launchd restart, it drags in a state
file that must run before everything else, and `CREATE TABLE dev.x` routes the write through
the client's catalog path instead of executing on the server. None of that exists with
`quack_query`.

## The body

Write the body as if you were sitting on the server, because you are. Tables are unqualified.
Joins, aggregates, CTEs, table functions, `CREATE OR REPLACE TABLE` — all normal.

One body, idempotent, standing alone. Do not use `.read`, `SET VARIABLE` or `getvariable()` to
sequence work across calls: they are CLI conveniences, they do not exist for the server, and a
body that depends on them is not re-runnable.

## Rules that still apply

- **Never open the database file.** Quack owns it; even `-readonly` is refused. A lock error
  means the caller is in the wrong place.
- **Never start a client with `-init`.** It *replaces* `~/.duckdbrc` rather than adding to it,
  dropping the 4 GiB / 4 thread floor and the per-process telemetry.
- **Spell it `quack:host:port`.** `quack://…` is silently not dispatched to the extension.
- **`LOAD` against the server is shared session state.** It succeeds — `lock_configuration`
  locks settings, not extension loading — but it changes the running server for every other
  client until launchd restarts it. `SET` is refused outright:
  `Cannot change configuration option "…" - the configuration has been locked`.
- **The server holds no secrets.** `$$FROM duckdb_secrets()$$` returns zero rows, so anything
  reaching for `s3://` fails at the first data read, not at attach time.
- **Ceilings are asymmetric.** Server 24 GiB / 10 threads; an ephemeral client 4 GiB / 4. One
  more reason the work belongs in the body.
- **The read-only listener** refuses anything its parser does not see as exactly one SELECT.
  "Authorization failed" on a write there is working as designed.

## Report

Name any server state you changed — a created or dropped table, a `LOAD`. It is a shared
server; those are not private.

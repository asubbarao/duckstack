---
name: ducklake
description: >
  Landing raw pulls in a DuckLake so a re-pull is a snapshot instead of an overwrite, and
  reaching a DuckLake catalog from this machine. Use when attaching a lake, when an insert
  produces a lake with no parquet in it, when a `ducklake:` ATTACH fails, when asked to
  backfill or re-pull a window, or when deciding where a raw table should live.
argument-hint: "[attach <catalog> <data-path> | snapshots | probe]"
allowed-tools: Bash
---

> **Provenance: DuckDB Labs, `installed_from = 'core'`.** DuckLake is DuckDB Labs' own
> lakehouse format, not a community extension. Do not rank it against community extensions on
> stars or downloads — adoption metrics are the only signal a community extension offers and
> they say nothing here.
>
> **Verified 2026-09-17 on this machine.** A local catalog with a local data path works end to
> end: create, insert, `snapshots()` and `AT (VERSION => n)` all ran. Only the **`s3://` data
> path** is unexercised, and that is a credentials gap, not a DuckLake one.

Read `/duckstack:duck` for the execution boundary and `/duckstack:quack` for how to call the
server. Everything below runs inside a `quack_query` body — there is no ATTACH to dev.

## 1. Why a lake rather than a plain table

Every INSERT into a DuckLake is a **snapshot**. That is the whole reason to use one as the
landing layer for raw pulls: re-running the same window adds a version instead of destroying
the previous one, so a backfill is auditable and a bad pull is recoverable rather than a lost
afternoon. `CREATE OR REPLACE TABLE` gives you the opposite — last writer wins and the
evidence is gone.

## 2. What is actually true here (verified 2026-09-17)

Each probe is the body of a `quack_query` call against `quack:localhost:9494`.

| Body | Result |
|---|---|
| `SELECT … FROM duckdb_extensions() WHERE extension_name = 'ducklake'` | `installed true`, `install_mode REPOSITORY` |
| `LOAD ducklake` | **succeeds** |
| `SET memory_limit='8GiB'` | refused — `Cannot change configuration option … the configuration has been locked` |
| `FROM duckdb_secrets()` | **0 rows** — no S3/R2/GCS credentials exist on dev |
| `FROM duckdb_databases() WHERE NOT internal` | one row, `dev` — nothing else attached |
| `current_setting('memory_limit')`, `current_setting('threads')` | `24.0 GiB`, `10` |

Two corrections to assumptions people carry in:

- **`LOAD` is not blocked, `SET` is.** `lock_configuration = true` locks *settings*. Loading an
  already-installed extension on dev works. Do not tell anyone `LOAD` is refused there.
  `INSTALL` is a separate question (`autoinstall_known_extensions = false`) and is unprobed —
  do not claim either way. Note that a `LOAD` against dev is shared session state: it changes
  the running server for every other client until launchd restarts it. Say so when you do it.
- **The server's ceilings are not the client's.** dev runs at 24 GiB / 10 threads; your
  ephemeral client runs at 4 GiB / 4 from `~/.duckdbrc`. A plan that fits on the server may not
  fit in the client — another reason the work belongs in the body.

## 3. Attach shape (local data path, verified)

A DuckLake is two things: a metadata catalog and a data path. The catalog can be a `.duckdb`
file, or postgres/sqlite when several processes share it. The data path is where the parquet
actually lands.

```sql
LOAD ducklake;
-- ATTACH 'ducklake:<metadata catalog>' AS <alias> (DATA_PATH '<data dir or s3 prefix>')
--   metadata catalog: a .duckdb file (or postgres:/sqlite: for a shared one)
--   DATA_PATH: where the parquet lands; needs no secret when it is local
ATTACH 'ducklake:/Users/aloksubbarao/.duck/lake/meta.ducklake' AS lake
  (DATA_PATH '/Users/aloksubbarao/.duck/lake/data/');
```

This is a `ducklake:` attach inside the body, not a `quack:` attach from the client — it is
unaffected by duckdb-quack#132.

## 4. The failure that produces no error

`DATA_INLINING_ROW_LIMIT` does **not** default to 0. Small inserts stay inlined in the metadata
database and never become parquet files. You get a lake that queries correctly, reports rows,
and has nothing under its data path — no error, no warning. Against a local path that is merely
confusing; against `s3://` it means the data never left the machine.

```sql
ATTACH 'ducklake:…' AS lake (DATA_PATH 's3://bucket/prefix/', DATA_INLINING_ROW_LIMIT 0);
```

## 5. Time travel, and dedupe as a view

```sql
SELECT snapshot_id, snapshot_time, changes FROM lake.snapshots() ORDER BY snapshot_id DESC;
SELECT count(*) FROM lake.<table> AT (VERSION => 1);
SELECT count(*) FROM lake.<table> AT (TIMESTAMP => now() - INTERVAL 1 HOUR);
```

**Never DELETE in the raw layer to deduplicate.** The raw layer's job is to be the record of
what the source returned; deleting from it destroys exactly the history the snapshots exist to
keep. Deduplication is a view on top, so the raw rows stay and the current view is derived:

```sql
CREATE OR REPLACE VIEW lake.<table> AS
SELECT * EXCLUDE (rn) FROM (
  SELECT *, row_number() OVER (PARTITION BY <key> ORDER BY pulled_at DESC) AS rn
  FROM lake.raw_<table>
) WHERE rn = 1;
```

Housekeeping is explicit and belongs in a maintenance window, never in a refresh:
`CALL lake.ducklake_expire_snapshots(older_than => now() - INTERVAL 90 DAY);`

## 6. The S3 blocker, stated plainly

`httpfs` and `aws` are both in `setup.sql` and both loaded, so the *filesystem* is there. But
`duckdb_secrets()` on the server returns **zero rows** — there are no credentials of any kind.
An `s3://` data path therefore fails at the first data read, not at `ATTACH`, which reads as a
DuckLake problem and is not one.

Credentials are a server concern. They belong in `~/inframe/internal/duckdb/setup.sql` as a
`CREATE SECRET`, never in a client `SET`, never as a literal. Endpoints, regions and URL styles
are secrets here too, not settings. Adding one means editing the source of truth plus a launchd
`bootout` + `bootstrap` — a deliberate change, not something a skill does on its own. Until one
exists, prove everything against a local data path.

## 7. Report

State whether the data path was local or remote, whether `DATA_INLINING_ROW_LIMIT` was set, and
the snapshot id the write produced. "It inserted fine" is not a result when the parquet may not
exist — check the data path. Say which claims you verified in *this* session versus took from
this file, and name any server state you changed.

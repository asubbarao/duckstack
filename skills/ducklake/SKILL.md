---
name: ducklake
description: >
  Reach a DuckLake catalog from this machine — what is actually wired, what is not, and the
  calling convention that agents get wrong. Use when asked to attach, read or write a
  DuckLake, when a ducklake ATTACH fails, or before writing any `ducklake:` SQL here.
argument-hint: "[probe | attach <catalog> <data-path>]"
allowed-tools: Bash
---

> **Provenance: DuckDB Labs, `installed_from = 'core'`.** DuckLake is DuckDB Labs' own
> lakehouse format, not a community extension. Do not rank it against community extensions on
> stars or download counts; no community extension is equivalent.
>
> **Verified 2026-09-17 on this machine.** A local catalog with a local data path works today:
> create, insert, `snapshots()` and `AT (VERSION => n)` all ran. The worked recipe is
> `shelf/ext/ducklake.sql` (in this plugin) — read it before writing anything here, it is the source
> of truth and this skill is the summary. Only the **`s3://` data path** is unexercised, and
> that is a credentials gap, not a DuckLake one.

Agents get DuckLake wrong here for one reason: they treat the dev DuckDB like a database file
they control. It is a locked, always-on quack server. Read `/duckdb-skills:duck` first.

## 1. What is actually true on this machine (verified 2026-09-17)

| Probe through `dev.query($$…$$)` | Result |
|---|---|
| `SELECT … FROM duckdb_extensions() WHERE extension_name = 'ducklake'` | `installed true`, `install_mode REPOSITORY` |
| `LOAD ducklake` | **succeeds** |
| `SET memory_limit='8GiB'` | refused — `Invalid Input Error: Cannot change configuration option "memory_limit" - the configuration has been locked` |
| `FROM duckdb_secrets()` | **0 rows** — no S3/R2/GCS credentials exist on dev |
| `FROM duckdb_databases() WHERE NOT internal` | one row, `dev` — nothing else is attached |
| `current_setting('memory_limit')`, `current_setting('threads')` | `24.0 GiB`, `10` |

Two corrections to assumptions people carry into this:

- **`LOAD` is not blocked, `SET` is.** `lock_configuration = true` locks *settings*. Loading an
  already-installed extension through `dev.query($$LOAD …$$)` works. Do not tell the user that
  `LOAD` is refused on dev; it is not. `INSTALL` is a separate question
  (`autoinstall_known_extensions = false`) and has not been probed — do not claim either way.
- **The server's ceilings are not the client's floor.** dev runs at 24 GiB / 10 threads. Your
  ephemeral `:memory:` client runs at 4 GiB / 4 threads from `~/.duckdbrc`. A plan that fits on
  the server may not fit in the client, which is another reason to push work into
  `dev.query($$…$$)` rather than stream rows out.

## 2. The blocker nobody names

A DuckLake is a catalog plus a data path. The data path is almost always `s3://`, and **dev has
no secrets at all**. `INSTALL httpfs` and `INSTALL aws` are in `setup.sql` and both are loaded,
so the *filesystem* is there — the *credentials* are not. Until a secret exists, an `s3://`
DuckLake will fail on the first data read, not on the `ATTACH`, which makes it look like a
DuckLake problem when it is a credentials problem.

Credentials are a server concern. They go in `~/inframe/internal/duckdb/setup.sql` as a
`CREATE SECRET`, never in a client `SET`, and never as a literal. Endpoints, regions and URL
styles are secrets here, not settings. Adding one means editing the source of truth and a
launchd `bootout` + `bootstrap` — a deliberate change, not something a skill does on its own.

A DuckLake whose data path is **local** sidesteps all of this and is the right way to exercise
the shape first.

## 3. The attach shape (verified, local data path)

```sql
LOAD ducklake;   -- verified: succeeds on dev

-- ATTACH 'ducklake:<metadata catalog>' AS <alias> (DATA_PATH '<data dir or s3 prefix>')
--   metadata catalog: a .duckdb file (or postgres:/sqlite: for a shared one)
--   DATA_PATH: where the parquet lands; needs no secret when it is local
ATTACH 'ducklake:/Users/aloksubbarao/.duck/lake/meta.ducklake' AS lake
  (DATA_PATH '/Users/aloksubbarao/.duck/lake/data/');
```

Every INSERT is a snapshot, which is the whole point for a landing layer: a re-pull of the
same window adds a version instead of overwriting one, so a backfill stays auditable.

```sql
SELECT snapshot_id, snapshot_time, changes FROM lake.snapshots() ORDER BY snapshot_id DESC;
SELECT count(*) FROM lake.raw_github_workflow_runs AT (VERSION => 1);
SELECT count(*) FROM lake.raw_github_workflow_runs AT (TIMESTAMP => now() - INTERVAL 1 HOUR);
```

Dedupe is a **view over the lake**, never a DELETE in the raw layer:

```sql
CREATE OR REPLACE VIEW lake.github_workflow_runs AS
SELECT * EXCLUDE (rn) FROM (
  SELECT *, row_number() OVER (PARTITION BY id ORDER BY pulled_at DESC) AS rn
  FROM lake.raw_github_workflow_runs
) WHERE rn = 1;
```

Housekeeping: `CALL lake.ducklake_expire_snapshots(older_than => now() - INTERVAL 90 DAY);`

**The S3 path is the unexercised one.** `DATA_INLINING_ROW_LIMIT` does not default to 0, so
small inserts stay inlined in the metadata DB and never become parquet — a lake with no files
in it and no error. Set it to 0 when the data must actually land:

```sql
ATTACH 'ducklake:…' AS lake (DATA_PATH 's3://bucket/prefix/', DATA_INLINING_ROW_LIMIT 0);
```

## 4. Calling convention — the part agents actually fumble

- **Never open the file.** `~/.duck/dev.duckdb` is locked by `com.inframe.quack`; even
  `-readonly` is refused. A lock error means the caller is wrong, not the server.
- **Never `-init`.** It replaces `~/.duckdbrc` and drops the resource floor and telemetry.
  Restore state with `-cmd ".read \"$STATE_DIR/state.sql\""`, which runs *after* the rc file.
- **Push joins into `dev.query($$…$$)`.** A single-table scan through the attach streams fine;
  joining two dev tables client-side fails with "Multiple streaming scans … not currently
  supported". A DuckLake join is a join.
- **`duckdb_tables()` client-side shows nothing** for a quack attach — the remote catalog is
  not mirrored. Ask the server: `dev.query($$FROM duckdb_tables()$$)`.
- **Spell it `quack:host:port`.** `quack://…` is silently not dispatched to the extension.
- **After a launchd restart**, `DETACH dev; ATTACH …` again — and anything you `LOAD`ed into
  the server's session is gone, because a `LOAD` is session state, not persisted config.

## 5. Report

State plainly which of these you verified in *this* session versus took from this file, and
name any server state you changed — a `LOAD` against dev alters the running server for
everyone until launchd restarts it.

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
> stars or download counts; no community extension is equivalent and the comparison is a
> category error.
>
> **Local maturity: unexercised.** Separately from the above: **no DuckLake catalog has ever
> been attached on this machine.** §3 is the documented shape, not a verified recipe. Report
> that honestly — it is a statement about this laptop, not about the project.

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

## 3. The attach shape (documented, NOT verified here)

```sql
-- Run inside dev.query($$…$$) so it lands on the server, not in your client.
LOAD ducklake;   -- verified: succeeds on dev

-- ATTACH 'ducklake:<metadata-catalog>' AS <alias> (DATA_PATH '<data dir or s3 prefix>')
--   metadata catalog: a .duckdb file, or postgres:/sqlite: for a shared catalog
--   DATA_PATH: where the Parquet actually lands; must end in a separator
ATTACH 'ducklake:metadata.ducklake' AS lake (DATA_PATH 'lake_data/');

-- DATA_INLINING_ROW_LIMIT default is NOT 0. Small inserts are inlined into the catalog and
-- never reach the data path -- you get a lake with no Parquet in it and no error. Set it to 0
-- when the point is files on disk/S3.
--   (source: ~/inframe/internal/duckdb/CONTEXT.md, maturity poc)
ATTACH 'ducklake:metadata.ducklake' AS lake (DATA_PATH 'lake_data/', DATA_INLINING_ROW_LIMIT 0);
```

Before trusting any of the above, probe it and report what actually happened:

```bash
duckdb :memory: -cmd ".read \"$STATE_DIR/state.sql\"" -c \
  "FROM dev.query(\$\$LOAD ducklake\$\$); FROM dev.query(\$\$FROM duckdb_databases()\$\$);"
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

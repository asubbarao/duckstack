# CONTEXT

Pinned versions: DuckDB **1.5.5** osx_arm64 (`d8cdaa33fd`), quack `c154811`,
duckdb_mcp `a6b8648` (v2.3.0), `superhuman_docs` `1d85c9e`.

## Verified 2026-09-17

- `SET` against dev is refused: `Invalid Input Error: Cannot change configuration option
  "memory_limit" - the configuration has been locked`.
- **`LOAD` against dev is NOT refused.** `dev.query($$LOAD ducklake$$)` succeeds for an
  already-installed extension. `lock_configuration = true` locks settings, not extension
  loading. This corrects the blanket "no SET/INSTALL/LOAD against dev" line in the `duck`
  skill; `INSTALL` remains unprobed — do not claim either way.
- A `LOAD` against dev is **session state on a shared server**. It changes the running server
  for every client until launchd restarts it, and it does not survive that restart.
- dev runs at `memory_limit 24.0 GiB`, `threads 10`. An ephemeral client runs at `4.0 GiB` /
  `4` from `~/.duckdbrc`. Different ceilings; size plans for the side they run on.
- `FROM duckdb_secrets()` on dev returns **0 rows**. No S3/R2/GCS credentials exist, so any
  `s3://` data path fails at first read, not at ATTACH.
- `httpfs`, `aws` and `ducklake` are all installed and loaded on dev.
- `superhuman_docs` registers **zero** functions and exactly one secret provider, `config`.
  It is a storage extension; `ATTACH` is the whole surface, and OAuth cannot feed it.

## Unexercised

- No DuckLake catalog has ever been attached on this machine. The `ducklake` skill documents
  the shape, not a verified run.
- `INSTALL` against dev.

## Provenance, not just maturity

`duckdb_extensions().installed_from` separates DuckDB Labs' own work from community packages.
Verified on dev 2026-09-17:

| extension | installed_from | version | description |
|---|---|---|---|
| `ducklake` | **core** | `d8a1881e` | Adds support for DuckLake, SQL as a Lakehouse Format |
| `quack` | **core** | `c154811` | The DuckDB 'Quack' Client/Server Protocol |
| `httpfs` | **core** | `827222f` | reading and writing files over HTTP(S) |
| `aws` | **core** | `efa54a9` | features that depend on the AWS SDK |
| `crawler` | community | `7725ede` | — |
| `webbed` | community | `73189d2` | — |

DuckLake is DuckDB Labs' lakehouse format. No community extension is equivalent, and judging
it by stars or weekly downloads is a category error. `install_mode` is `REPOSITORY` for both
kinds and is **not** the discriminator — `installed_from` is.

Keep the two questions apart: *has it been exercised here* (local, applies to everything,
including DuckLake) versus *is it trustworthy at all* (provenance, already answered for core).

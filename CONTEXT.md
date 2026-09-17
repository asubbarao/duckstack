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

### Code and CI as tables (local client only; verified on real runs)

- Local client (`~/.duckdb/extensions`) has `duck_tails` 742af7b, `gh` 10d642a, `sitting_duck`
  b8c06a8, `duck_hunt` 68ca1c4 (installed today), `zipfs` (installed today). The dev server
  (`~/.duck/extensions`) has `duck_tails` and `cloudwatch` d404b01; none of the others.
- `duck_tails` 742af7b: `git_diff_tree(repo_or_dir [, from_ref [, to_ref]])` — first positional
  is a **path**; with one ref it diffs that ref against the working tree. `text_diff` is a
  positional line walk (not Myers). `text_diff_lines()` returns a hard-coded 3-row sample
  regardless of input and `text_diff_stats()` returns a constant string — both are stubs in this
  build; the readthedocs pages describe a newer commit (1223e5d). `git_status` and
  `git_diff_tree` exist and are undocumented. Named parameters do not bind inside `LATERAL`.
- `duck_hunt` on a GitHub Actions run ZIP (`gh api …/actions/runs/<id>/logs`): the workflow
  parser yields step tree + `unit_status`; delegation to tool parsers (level 4) fired on
  **neither** quackapi (build inside `docker run`) nor inframe (`uv run pytest`). Re-read the
  job file with the tool parser. `pytest_text` returns **0 rows** on pytest-xdist `-v` output
  (`[gwN] [ pct%] PASSED nodeid`); a `regexp:` format with named groups recovers every test
  (18,145 across three inframe shards, counts equal to the summary lines). `make_error` is
  what surfaces `make: *** [...] Error 134`.
- `sitting_duck` b8c06a8 on `platform/backend/app/**/*.py`: 2,148 files, 182,259 named
  definitions in ~1 s wall (`context := 'native', source := 'lines', peek := 'none'`).
  `functions` is a reserved word — quote it as an alias.
- inframe Sentry: org `inframe-risk`, projects `inframe-backend` (id 4510993430806528),
  `inframe-broker`, `inframe-hub`, `inframe-lead-capture`, `inframe-portal`,
  `inframe-precheck`, `scout`. Alert rule `production-backend` (16761007) and the staging
  workflow (3980918) post only to Slack `#itops-prod-issues` (C0AJV462T4K) and to DMs;
  `#inframe-os` (C0BKMLQ6URE) is humans reporting product issues, no Sentry bot.

## Unexercised

- The `s3://` DATA_PATH for DuckLake (local catalog + local data path IS verified — see
  ~/duckdb-flying/ext/ducklake.sql). Blocked on dev having zero secrets, not on DuckLake.
- `INSTALL` against dev.
- `cloudwatch` on dev: installed, never called; no AWS secret exists on dev (see above), so
  `read_cloudwatch_logs` would fail at the first call. `references/gh_cloudfront_cloudwatch.md`
  documents the surface from source, not from a run.
- `sitting_duck` macros (`ast_select`, call-graph macros): the table functions were run; the
  macro layer is documented from source only (`references/sitting_duck.md`).

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

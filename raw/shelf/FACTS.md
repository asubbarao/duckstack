# FACTS — engine behaviour verified on this machine

Engine facts only: true of DuckDB and these extensions anywhere. Facts about InFrame's servers,
secrets and services live in `inframe/internal/duckdb/CONTEXT.md` (ADR-002).
Pinned: DuckDB **1.5.5** osx_arm64 (`d8cdaa33fd`), quack `c154811`, duckdb_mcp `a6b8648`
(v2.3.0), `superhuman_docs` `1d85c9e`.

## Verified 2026-09-17

- **`lock_configuration = true` locks settings, not extension loading.** `SET` is refused
  ("the configuration has been locked"); `query($$LOAD ducklake$$)` on a locked server
  succeeds for an installed extension and changes that server for every client until restart.
  `INSTALL` against a locked server is unprobed.
- `superhuman_docs` registers **zero** functions and one secret provider, `config`. It is a
  storage extension: `ATTACH` is the whole surface; OAuth cannot feed it.
- `quack://host:port` works for `quack_query` and `ATTACH` (quack c154811); `quack:host:port`
  stays the house spelling because secret `SCOPE` is a literal prefix match.
- A `duckdb` started with `-init` replaces `~/.duckdbrc` entirely; `-c`, `-f`, `-cmd` keep it.
- DuckLake: `AT (VERSION => n)` accepts a literal only (no column, no subquery) — time travel
  is two statements. `INSERT … RETURNING` into a DuckLake table is not supported. One
  transaction = one snapshot; `ducklake_set_commit_message(catalog, author, message)` signs it.
  `DATA_PATH` is fixed at first ATTACH; later ATTACHes must match or omit it.
- quackapi 398d42c: `quackapi_serve` sets `memory_limit = 256MB`, `preserve_insertion_order =
  false`, `threads = all` unless told otherwise; `query($q)` in a route is SELECT-only; a
  failing handler returns `500 {"detail":"Internal Server Error"}` with the message on stderr;
  a `$param` missing from the body is a 422 unless declared `PARAM x TYPE DEFAULT NULL`; a JSON
  `null` binds as the string `'null'`. No `quackapi_wait`, `block :=`, or middleware in this build.
- `try()` refuses to wrap a volatile call directly (`try(f(http_post(…)))` is a binder error);
  go through a subquery.
- `read_csv('cmd |')` (shellfs) is literal-only: a column argument is refused.

### Code and CI as tables (local client)

- `duck_tails` 742af7b: `git_diff_tree(repo_or_dir [, from_ref [, to_ref]])` — first positional
  is a **path**; with one ref it diffs that ref against the working tree. `text_diff` is a
  positional line walk (not Myers). `text_diff_lines()` returns a hard-coded 3-row sample and
  `text_diff_stats()` a constant string — stubs in this build; the docs describe 1223e5d.
  `git_status` and `git_diff_tree` exist and are undocumented. Named parameters do not bind
  inside `LATERAL`. `git_read` is literal-only: use `git_tree … LATERAL git_read_each(git_uri)`.
- `duck_hunt` on a GitHub Actions run ZIP: the workflow parser yields the step tree +
  `unit_status`; delegation to tool parsers did not fire when the build ran inside `docker run`
  or `uv run pytest`. `pytest_text` returns **0 rows** on pytest-xdist `-v` output; a `regexp:`
  format with named groups recovers every test. `make_error` surfaces `make: *** [...] Error N`.
  The zip reader expects `{N}_{job}.txt` member names; `gh api …/logs` zips with spaces need
  unzipping. `format := 'github_actions_text'` is invalid — use `'auto'`. Literal-only.
- `sitting_duck` b8c06a8: ~2,100 Python files → ~182k named definitions in ~1 s with
  `context := 'native', source := 'lines', peek := 'none'`. `functions` is a reserved word.

## Unexercised (say so when relying on them)

- DuckLake with an `s3://` `DATA_PATH`.
- `INSTALL` against a locked server.
- `cloudwatch` calls (surface documented from source only).
- `sitting_duck` macros (`ast_select`, call-graph macros): documented from source only.

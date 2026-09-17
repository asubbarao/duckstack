---
name: duck-hunt
description: >
  Test results, build output, lint output and CI job logs as tables — "readable CI". duck_hunt
  parses 110 tool formats plus GitHub Actions / GitLab / Jenkins / Docker workflow logs into one
  39-column event schema (status, severity, ref_file, ref_line, test_name, fingerprint, …). Use
  when asked why CI is red, what a run's tests did, to diff two runs, to cluster build errors, or
  to land a job log on dev as rows. Pairs with git-github (`gh` CLI fetches the run, duck_hunt
  reads it) and with duck_tails (blame the ref_file:ref_line the parser points at).
argument-hint: "<run id | log path | 'this PR'> [question]"
allowed-tools: Bash
---

Everything below was verified 2026-09-17 on this machine: DuckDB 1.5.5 osx_arm64, `duck_hunt`
68ca1c4 and `zipfs` installed in `~/.duckdb/extensions` for the **local client only**. Neither is
on the dev server; parse in the `:memory:` client and land results with `dev.query($$CREATE TABLE
… AS …$$)` or `COPY … TO` parquet. Read `/duckdb-skills:duck` §4 first — the SQL process rules
apply (reader first, keep the row, `array_agg` over `count` in base layers).

## Get the log as a file, then read it

The `gh` CLI is logged in as `asubbarao-ifr`. A run's logs come down as a ZIP of
`{N}_{job name}.txt` files; that ZIP is the unit of work.

```bash
gh run list -R <owner>/<repo> --limit 10                       # find the run id
gh api repos/<owner>/<repo>/actions/runs/<run_id>/logs > run.zip   # every job, every step
gh run view <run_id> -R <owner>/<repo> --log-failed > failed.log   # only the failed jobs, flat
```

```sql
LOAD zipfs; LOAD duck_hunt;

-- read_duck_hunt_workflow_log(source, format) ; format: auto|github_actions|gitlab_ci|jenkins|docker_build|spack|github_actions_zip
-- named: severity_threshold := 'all'      (ignore_errors is accepted and ignored)
-- returns 44 cols: the 39-col event schema minus log_file, plus workflow_type, hierarchy_level, parent_id, job_order, job_name
FROM read_duck_hunt_workflow_log('run.zip', 'github_actions_zip');        -- whole run, job_order/job_name filled
FROM read_duck_hunt_workflow_log('zip://run.zip/6_Backend Tests Shard 3.txt', 'github_actions');   -- one job

-- read_duck_hunt_log(source, format := 'auto', severity_threshold := 'all', content := 'full', context := 0)
-- source: path | glob | zip://… | /dev/stdin | .gz ; format: any of duck_hunt_formats().format, an alias,
--         a group ('python','test','build','lint','ci','logging'), a chain 'gcc_text,make_error', or 'regexp:<pattern>'
FROM read_duck_hunt_log('zip://run.zip/*Backend Tests Shard*.txt', 'pytest_text');   -- glob inside a zip works
FROM parse_duck_hunt_log(<varchar>, 'auto');                                          -- same schema, from a string; log_file NULL
```

Start with the contest, not the parse — `auto` looks at the first 8 KB only:

```sql
FROM duck_hunt_diagnose_read('failed.log') WHERE can_parse;    -- format, priority, events_produced, is_selected
```

## What a GitHub Actions job log yields here (measured)

| Job log | Reader | Result |
|---|---|---|
| quackapi PR #25 failed job (`4_Build extension binaries _ linux_amd64.txt`, 618 KB) | workflow `github_actions` | 76 rows, 16 steps with `unit_status`; the one `severity='error'` row is `##[error]Process completed with exit code 2` — the real cause is not surfaced |
| same file | `make_error` | the row that matters: `make: *** [extension-ci-tools/makefiles/duckdb_extension.Makefile:218: test_release] Error 134` (134 = SIGABRT) |
| same file | `duckdb_test` | one INFO summary row; 0 FAIL — because all 25 test cases passed and the crash was at process exit (`malloc(): unsorted double linked list corrupted`) |
| same file | `gcc_text` | 7 rows, 1 "error" that is really the `docker run` wrapper line — ignore |
| inframe CI run 35195699417 (13 jobs, 6.7 MB) | `github_actions_zip` | 19,297 rows in ~2 s; 2 false "errors" in Backend Tests Shard 3 (PASSED lines containing the word error), 2 real ones in Local Dev Smoke (`mc: <ERROR> … bucket CORS`, `bootstrap.clerk_error`) |
| inframe backend test shards | `pytest_text` | **0 rows.** pytest-xdist `-v` prints `[gw0] [ 12%] PASSED nodeid`; `pytest_text` wants `nodeid PASSED`. |
| inframe backend test shards | `regexp:` (below) | 18,145 tests, 20 SKIPPED, 0 FAILED — matches the three `=== N passed ===` summary lines exactly |

So: the workflow parser gives you the step tree and statuses; the tool parsers give you the
diagnostics; **delegation (hierarchy_level 4) did not fire on either repo** — quackapi builds inside
`docker run` and inframe's steps are `uv run pytest …`, neither matches the `Run <cmd>` patterns.
Read the job file a second time with the tool parser you expect.

## pytest-xdist: the petition and the reader

`regexp_*` in SQL stays banned. This is duck_hunt's own `regexp:` *format* — the reader for a shape
no built-in parser covers — and the petition is the row above: `pytest_text` returns 0 rows on
xdist output. Named groups map onto schema columns (`severity`, `file`, `test_name`, `message`,
`line`, `code`, `tool`).

```sql
CREATE TEMP TABLE tests AS
SELECT log_file, severity AS outcome, ref_file AS file, test_name, log_line_start
FROM read_duck_hunt_log('zip://run.zip/*Backend Tests Shard*.txt',
  'regexp:\[gw\d+\] \[\s*\d+%\] (?P<severity>PASSED|FAILED|SKIPPED|ERROR|XFAIL|XPASS) (?P<file>[^:\s]+)::(?P<test_name>\S+)');

SELECT log_file, outcome, array_agg(file || '::' || test_name) AS tests, len(tests) AS n
FROM tests WHERE outcome <> 'PASSED' GROUP BY ALL;

-- the summary lines, same reader
FROM read_duck_hunt_log('zip://run.zip/*Backend Tests Shard*.txt', 'regexp:=+ (?P<message>\d+ passed.*) =+');
```

The permanent fix is upstream of DuckDB: add `--json-report --json-report-file=report.json` to
the pytest step and upload it; `pytest_json` (priority 100, `execution_time` in seconds, one row
per test, summary row with counts) needs no regex.

## The schema you get back (the columns that matter)

`event_id` (restarts per file and per LATERAL row — never a key), `tool_name`, `event_type`
(**lowercase**: `test_result`, `build_error`, `lint_issue`, `summary`, …), `ref_file`, `ref_line`,
`function_name`, `status` (**UPPER**: `PASS FAIL ERROR WARNING INFO SKIP`), `severity` (**lower**:
`debug info warning error critical`), `category`, `error_code`, `message`, `suggestion`,
`log_content`, `structured_data` (JSON counts on summaries; on workflow rows the delegated
format), `log_line_start`/`log_line_end` (line in the log, 1-indexed), `log_file`, `test_name`,
`execution_time` (whatever the tool printed — pytest seconds; 0.0 not NULL when unknown),
`started_at` (VARCHAR), `scope`/`"group"`/`unit` (+`_id`, `_status`: workflow / job / step —
`group` needs quoting), `fingerprint`, `pattern_id`, `similarity_score`.

Empty-not-NULL: `ref_file`, `function_name`, `category`, `error_code`, `message`, `test_name`.
`fingerprint`/`pattern_id` are NULL in streaming mode (single file, `context := 0`, streaming
parser); a glob or `context := 1` forces batch mode and fills them. `fingerprint` embeds
`std::hash` — stable inside one binary, not across machines; don't persist it as a key.

## Gotchas that cost time today

- `LOAD zipfs` before any `zip://` or `github_actions_zip` read; it is a separate community extension.
- `git`-style `..` in a path is refused (`Invalid file path`). Give absolute or clean relative paths.
- A missing file returns **0 rows, no error**, `ignore_errors` or not. Check `count(*)` before trusting an empty result.
- `severity_threshold` typos silently become `'warning'` and drop every PASS row.
- Named parameters do not bind inside `LATERAL` (`severity_threshold := 'x'` becomes a column ref). Filter in `WHERE` instead.
- `read_duck_hunt_workflow_log` is not an in-out function: it cannot take a column as source. `read_duck_hunt_log` / `parse_duck_hunt_log` can (`FROM t, LATERAL parse_duck_hunt_log(t.content, 'auto') e`).
- A format ending in `.json` or starting `config:` is fetched as a **custom parser config**, not a format name. Never write `format := 'eslint.json'`.
- `execution_time` unit is the tool's; docs disagree with themselves (ms vs s). pytest and go test are seconds.
- Windows binaries do not exist; macOS arm64 and Linux do.
- No k6 / benchmark parser exists. `bench/` output from quackapi is a `regexp:` job or DuckDB's own `read_json` on k6 `--out json`.
- `duck_hunt_detect_format()` returns the string `'unknown'`, not NULL.

## Landing it on dev

```sql
-- one run → one table, raw first, then the views
LOAD quack; ATTACH 'quack:localhost:9494' AS dev (TYPE quack, TOKEN getenv('QUACK_TOKEN'));
CREATE TEMP TABLE run AS FROM read_duck_hunt_workflow_log('run.zip', 'github_actions_zip');
-- ci_events(run_id, job_order, job_name, unit, unit_status, severity, status, tool_name, ref_file, ref_line, message, started_at, fingerprint)
INSERT INTO dev.ci_events SELECT 35195699417 AS run_id, job_order, job_name, unit, unit_status, severity, status, tool_name, ref_file, ref_line, message, started_at, fingerprint FROM run;
```

Cross-run questions are then joins on `(job_name, unit, fingerprint)`; the flaky-test question is
`tests` (above) grouped by `file, test_name` across runs with `array_agg(outcome)`.

## Where the reference lives

`references/duck_hunt.md` in this repo — every function, every format string with maturity, all
docs examples, and the 20-odd places the docs and the shipped source disagree.

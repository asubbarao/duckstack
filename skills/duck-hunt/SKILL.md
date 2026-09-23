---
name: duck-hunt
description: >
  Test results, build output, lint output and CI job logs as tables ("readable CI"). duck_hunt
  parses 110 tool formats and GitHub Actions / GitLab / Jenkins / Docker workflow logs into one
  40-column event schema (status, severity, ref_file, ref_line, test_name, fingerprint, …). Ships
  a growing library of tested views in recipes.sql: pytest_xdist_tests, vitest_files,
  vitest_phases, gha_steps, gha_errors, biome_diagnostics, failure_clusters,
  recurring_diagnostics. Every CI/CD analysis adds its new readings there and its new gotchas to
  Learned. Use when asked why CI is red, what a run's tests did, to diff two runs, to cluster
  failures by fingerprint, to find failures that recur across runs, to land a job log as rows, or
  to time tests from a log that prints no durations. Regex on log text is allowed. Pairs with
  ci-timing (runs, jobs, steps), duck_tails (blame the ref_file:ref_line the parser points at)
  and live-page (render the result).
argument-hint: "<run id | log path | 'this PR'> [question]"
allowed-tools: Bash, mcp__dev__ci_hunt
---

**After every CI/CD analysis, add each new log reading to `recipes.sql` as a view, with the
question it answers and one verified line. Add each new gotcha to §Learned as a dated one-liner.
Don't inline one-offs.** The library only improves if every analysis leaves something in it.

Where it runs: this doc and `recipes.sql` (next to it), in your own `duckdb :memory:` or through
`uvx --from duckdb duckdb`. The `dev` MCP tool `ci_hunt(zip, glob, format)` is a shortcut for one
read over an Actions log zip. Recipes are views, never macros. A page built from them is
`/duckstack:live-page`.

## Recipes: `recipes.sql`

Land each job's log as `raw/joblog-<job_id>.txt`:

```bash
gh api --allow-escape-sequences repos/o/r/actions/jobs/<id>/logs > raw/joblog-<id>.txt
```

Then `LOAD duck_hunt; .read <skill dir>/recipes.sql` from that folder. Every view carries `job_id`,
parsed from the file name, so you can join it back to the jobs API.

| View | Question | Verified 2026-09-23 |
|---|---|---|
| `pytest_xdist_tests` | how long did each backend test take? Measured as the gap to the previous line on its xdist worker | 19,187 tests over 3 shards |
| `vitest_files` | which vitest files are slow? | 545 files; RequestPicker.test.tsx 14.8 s |
| `vitest_phases` | where does a vitest shard's wall time go (import, environment, tests)? | phases = 95% of wall: files run one at a time |
| `gha_steps` | when did each step start and how long did it run, from the log alone? | pytest step 566.6 s, API 566 s |
| `gha_errors` | which `##[error]` annotations did each job raise? | 5 failed jobs |
| `biome_diagnostics` | which lint rule fired where, and which one failed the job? Uses `context := 3` | the one `×` error found |
| `failure_clusters` | which error messages repeat, and in which jobs? Keyed on `fingerprint` | 1 cluster, 5 jobs, 3 runs |
| `recurring_diagnostics` | which lint findings recur across jobs and runs? Keyed on rule + file | noArrayIndexKey in 3 of 3 |

Each view re-parses its logs whenever it is queried, which takes about 10 s per 7 MB. An analysis
that reads a view more than once lands it first: `CREATE OR REPLACE TABLE x AS FROM <view>`.

## Learned

Dated one-liners. Add to this list; don't rewrite it.

- 2026-09-23: fetching per-job logs.
  - Save the per-job log to a file first with `gh api --allow-escape-sequences …/jobs/<id>/logs > f`,
    then read the file. Piping gh straight into shellfs failed.
  - The per-job log needs no zip and no zipfs.
- 2026-09-23: `regexp:` readers and globs.
  - `regexp:` readers take a glob and fill `log_file`, although the docs say globs are unsupported.
  - Each file with no match adds one `info` row reading "No matches found …". Filter it out.
- 2026-09-23: the workflow parser on per-job logs.
  - `read_duck_hunt_workflow_log` takes a single file. Given a glob it returns one summary row.
  - On a per-job log it names most steps "Unnamed Step" and folds the test run into "Job Level".
    Take step times from the jobs API, or from `gha_steps`.
  - `read_duck_hunt_log(…, 'github_actions')` returns 0 rows on a per-job log.
- 2026-09-23: `regexp:` pattern quirks.
  - A plain `( )` group shifts the mapping of the named groups after it. Write non-captured parts as `(?:…)`.
  - A `status` group is ignored. Status comes only from `severity`/`level`.
- 2026-09-23: clustering keys.
  - `pattern_id` is renumbered on every call. Cluster and join on `fingerprint`, which is a hash of
    the normalized message and is stable across calls.
  - `similarity_score` was always 1.0.
  - A timestamp captured into `message` makes every fingerprint unique. Capture it into `code` instead.
- 2026-09-23: `context := N` adds `context STRUCT(line_number, content, is_event)[]`, N lines each
  side. Use it to read the line after a match, such as Biome's `×` / `!` severity.
- 2026-09-23: `regexp_extract` is hook-banned in SQL. Split a log line on its literal punctuation
  with `string_split` (see `vitest_phases`), or capture the value with a named group.
- 2026-09-23: broken in duck_hunt 68ca1c4. `parse_duck_hunt_workflow_log` returns 0 rows, and
  `duck_hunt_match_command_patterns` errors because RE2 does not support lookaheads.
- 2026-09-23: duck_tails. A relative `git://path@ref` resolves only when the working directory is
  the repo root. From a subfolder it returns 0 rows with no error, so use `git:///<abs repo root>/path@ref`.
- 2026-09-23: `status_badge(status)` and `status_badge(errors, warnings[, running])` return `[FAIL]`,
  `[WARN]`, `[ OK ]`, `[ .. ]` or `[ ?? ]`. Useful as a page's status column.

Everything below was verified on this machine (2026-09-17, extended 2026-09-22): DuckDB 1.5.5
osx_arm64, `duck_hunt` 68ca1c4 and `zipfs`. Parse in your own `:memory:` client
(`INSTALL duck_hunt FROM community; LOAD duck_hunt; INSTALL zipfs FROM community; LOAD zipfs;`
— always allowed), or on dev: `~/duckdb-skills/server/setup.sql` loads both and the dev MCP
publishes `ci_hunt(zip, glob, format)` over `read_duck_hunt_log('zip://' || zip || '/' || glob, format)`
(`/duckstack:agent-door`). Land client-side results on dev with
`quack_query('quack:localhost:9494', $$CREATE OR REPLACE TABLE … AS …$$, token := getenv('QUACK_TOKEN'))`
or write them out with `COPY … TO` parquet. Read `/duckstack:duck` §4 and `/duckstack:quack`
first — the SQL process rules apply (reader first, keep the row, `array_agg` over `count` in
base layers). Where the run and its zip come from, and the timing questions, are
`/duckstack:ci-timing`.

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

## pytest-xdist: the reader

Regex on log text is allowed (Alok, 2026-09-22: "I don't care if you use regex on websites";
CI and tool logs are the same case — unstructured text no reader infers). It stays banned on
backend queries and on anything structured (paths, hive keys, JSON, timestamps). Say so in one
line when you use it. duck_hunt's own `regexp:` *format* is the reader for a shape no built-in
parser covers — `pytest_text` returns 0 rows on xdist output (row above). Named groups map onto
schema columns (`severity`, `file`, `test_name`, `message`, `line`, `code`, `tool`).

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

### Per-test time from the Actions timestamps

xdist prints no durations, but every Actions log line starts with a UTC timestamp. Keep it in
`message` and the worker in `code`; a test's wall time is the gap to the previous result line
**on the same worker** (so it includes that test's fixtures — the number a human cares about):

```sql
-- read_duck_hunt_log(source, format := 'auto', severity_threshold := 'all', content := 'full', context := 0)
CREATE OR REPLACE TABLE raw_tests AS
SELECT * FROM read_duck_hunt_log('zip://raw/run-<id>.zip/*Backend Tests Shard*.txt',
  'regexp:(?P<message>\S+Z) \[(?P<code>gw\d+)\] \[\s*\d+%\] (?P<severity>PASSED|FAILED|SKIPPED|ERROR|XFAIL|XPASS) (?P<file>[^:\s]+)::(?P<test_name>\S+)');

CREATE OR REPLACE TABLE tests AS
SELECT log_file, right(message, 28)::TIMESTAMP AS ts, error_code AS gw, severity AS outcome,
       ref_file AS file, test_name,
       date_diff('millisecond', lag(ts) OVER (PARTITION BY log_file, gw ORDER BY ts), ts) AS ms
FROM raw_tests;
```

- `right(message, 28)` — the first line of each job file carries a UTF-8 BOM before the
  timestamp; the last 28 characters are the timestamp alone.
- `PARTITION BY log_file, gw` — one shard file, one xdist worker. The first test on each worker
  has `ms` NULL (no previous line); keep the row.
- Per shard: `list_sum(array_agg(ms) FILTER (WHERE ms IS NOT NULL))` is its worker-seconds —
  the shard-balance number `/duckstack:ci-timing` compares.

**Plateaus are timeouts, not work.** A test that lands within a few ms of a round number of
seconds (5.0 s, 10.0 s) is waiting on a timeout or a retry sleep — the cheapest seconds to win:

```sql
SELECT round(ms / 1000.0) AS plateau_s,
       array_agg(file || '::' || test_name ORDER BY file, test_name) AS names, len(names) AS n
FROM tests
WHERE ms IS NOT NULL AND abs(ms - round(ms / 1000.0) * 1000) < 150 AND ms >= 2000
GROUP BY plateau_s ORDER BY plateau_s DESC;
```

## vitest: the per-file reader

vitest prints one line per test file: `✓ src/…/X.test.tsx (83 tests) 15247ms`, wrapped in ANSI
colour codes. Verified 2026-09-22 on inframe run 35796637550 (three frontend shards):

```sql
CREATE OR REPLACE TABLE raw_fe AS
SELECT * FROM read_duck_hunt_log('zip://raw/run-<id>.zip/*Frontend Tests Shard*.txt',
  'regexp:(?P<message>\S+Z)  \S+ (?P<file>src/\S+) \S*?\(\S*?(?P<code>\d+) tests\S* (?P<line>\d+)\S*ms');
-- ref_file = the test file, error_code = its test count (VARCHAR), ref_line = its wall ms (INTEGER)
SELECT log_file, ref_file, error_code::INTEGER AS n_tests, ref_line AS file_ms
FROM raw_fe ORDER BY file_ms DESC;
```

| pattern around `(?P<code>\d+)` | result on that run |
|---|---|
| `\S*?\(\S*?` (non-greedy) | **545 files, 6,651 tests** — against 553 files / 6,659 tests in the shards' own summary lines; the 8 missing files print no `✓` line |
| `\S*\(\S*` (greedy) | 545 files but only 2,641 tests: the greedy `\S*` eats every digit but the last, so `83` reads as `3` |
| `\S*\(\D*` | 3 rows, `code` empty — `\D` matches nothing in duck_hunt's regexp engine; don't use it |

The `\S+`/`\S*?` around `✓` and the parentheses swallow the ANSI escapes; the summary lines
(`Test Files … 185 passed`, `Tests … 2384 passed`, `Duration 383.58s (transform, setup, import, tests, environment)`)
read with `'regexp:(?P<message>\s+(Test Files|Tests|Duration)\s.*)'` — plus one stray row per shard
from the `Frontend Tests Shard N` header line; `import` (≈150 s) rivals `tests` (≈125 s).

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

ATTACH to a quack server is blocked on this machine; the result travels as a file. Parse in the
client, write parquet, then read that file on dev (the `sql` MCP tool, or `quack_query`):

```sql
-- client (duckdb :memory:): one run → one parquet file, raw first
LOAD zipfs; LOAD duck_hunt;
COPY (SELECT 35195699417 AS run_id, * FROM read_duck_hunt_workflow_log('run.zip', 'github_actions_zip'))
  TO 'raw/ci_events-35195699417.parquet' (FORMAT parquet);

-- dev (the `sql` tool): the table is the union of every landed run
CREATE OR REPLACE TABLE ci_events AS
SELECT * FROM read_parquet('/abs/path/raw/ci_events-*.parquet', union_by_name := true, filename := true);
```

Cross-run questions are then joins on `(job_name, unit, fingerprint)`; the flaky-test question is
`tests` (above) grouped by `file, test_name` across runs with `array_agg(outcome)`.

## Where the reference lives

`references/duck_hunt.md` in this repo — every function, every format string with maturity, all
docs examples, and the 20-odd places the docs and the shipped source disagree.

## JUnit artifacts beat log timestamps (verified 2026-09-22)

When CI uploads JUnit XML (`pytest --junitxml`, vitest `--reporter=junit` — inframe PR #1314),
`junit_xml` (priority 100 in `duck_hunt_formats()`) reads it with each test's own
`execution_time`; no `regexp:` reader, no timestamp gaps:

```sql
-- gh run download <run_id> -n test-report-backend-1 -D reports
-- read_duck_hunt_log(source, format, severity_threshold := 'all', content := 'full', context := 0)
SELECT log_file, test_name, status, execution_time
FROM read_duck_hunt_log('reports/*/*.xml', 'junit_xml') ORDER BY execution_time DESC;
-- run 35254556687: 4,673 backend tests / 641 s in one shard, 2,186 vitest tests / 105 s; the
-- 5.02 s create_pool cluster shows up identically to the timestamp method.
```

The docs to read first: https://duck-hunt.readthedocs.io/en/latest/schema/ (the 39-column
event schema: `execution_time` is seconds; `status` upper, `severity` lower) and
https://github.com/teaguesterling/duck_hunt/blob/main/docs/examples.md (pytest JSON, Go test,
GitHub Actions, `context := N` for surrounding lines, cross-run `fingerprint` joins).
Prefer, in order: a native test report (`junit_xml`, `pytest_json`) → the workflow parser
for step units → the `regexp:` reader over timestamped lines.

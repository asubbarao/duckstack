-- duck_hunt recipes: named views over GitHub Actions per-job logs.
--
-- Landing convention (every recipe reads it): one plain-text job log per file, raw/joblog-<job_id>.txt,
--   gh api --allow-escape-sequences repos/<owner>/<repo>/actions/jobs/<job_id>/logs > raw/joblog-<job_id>.txt
-- Use:  LOAD duck_hunt;  .read <this file>  from the folder that holds raw/, then SELECT from the view you need.
-- Each view re-parses every matching log when queried (≈10 s per 7 MB), so an analysis that reads one twice
-- lands it once: CREATE OR REPLACE TABLE x AS FROM <view>.
-- Regular expressions here run on CI log lines only (duck_hunt regexp: readers), never on backend data.
-- No macros: every recipe is a view. A new log reading is added here as a view with its question and one
-- verified line; it is not inlined into an analysis.
--
-- read_duck_hunt_log(source, format := 'auto', severity_threshold := 'all', ignore_errors := false,
--                    content := 'full', context := 0)   -- source may be a glob; log_file says which file
-- A regexp: reader yields one stray 'info' row ("No matches found …") per file it does not match; the views drop it.

-- pytest_xdist_tests — how long did each backend test take? xdist prints no durations, so a test's time is the
-- gap to the previous result line on the same worker (fixtures included). The first test on a worker has ms NULL.
-- verified 2026-09-23, inframe run 35831860669: 19,187 tests over 3 shards, 2 workers each.
CREATE OR REPLACE VIEW pytest_xdist_tests AS
WITH r AS (
  SELECT string_split(parse_filename(log_file, true), '-')[2]::BIGINT AS job_id,
         right(message, 28)::TIMESTAMP AS ts,              -- the last 28 chars: the first line carries a BOM
         error_code AS gw, severity AS outcome, ref_file AS file, test_name
  FROM read_duck_hunt_log('raw/joblog-*.txt',
    'regexp:(?P<message>\S+Z) \[(?P<code>gw\d+)\] \[\s*\d+%\] (?P<severity>PASSED|FAILED|SKIPPED|ERROR|XFAIL|XPASS) (?P<file>[^:\s]+)::(?P<test_name>\S+)')
  WHERE severity IN ('PASSED', 'FAILED', 'SKIPPED', 'ERROR', 'XFAIL', 'XPASS'))
SELECT *, file || '::' || test_name AS nodeid,
       date_diff('millisecond', lag(ts) OVER (PARTITION BY job_id, gw ORDER BY ts), ts) AS ms
FROM r;

-- vitest_files — which vitest files are slow? One "✓ src/x.test.tsx (83 tests) 14817ms" line per file,
-- ANSI codes between the tokens; the non-greedy \S*? keeps every digit of the test count.
-- verified 2026-09-23, run 35831860669: 545 files over 3 shards; RequestPicker.test.tsx 14.8 s.
CREATE OR REPLACE VIEW vitest_files AS
SELECT string_split(parse_filename(log_file, true), '-')[2]::BIGINT AS job_id,
       ref_file AS file, error_code::INT AS n_tests, ref_line AS file_ms
FROM read_duck_hunt_log('raw/joblog-*.txt', 'regexp:(?P<message>\S+Z)  \S+ (?P<file>src/\S+) \S*?\(\S*?(?P<code>\d+) tests\S* (?P<line>\d+)\S*ms')
WHERE starts_with(ref_file, 'src/');

-- vitest_phases — where does a vitest shard's wall time go? Its closing line
-- "Duration 386.33s (transform 8.35s, setup 8.68s, import 153.54s, tests 124.27s, environment 72.56s)" split on
-- its literal punctuation. Phases summing to ≈ the wall means files ran one at a time.
-- verified 2026-09-23, run 35831860669: phases = 95% of wall on all three shards; import 153 s vs tests 124 s.
CREATE OR REPLACE VIEW vitest_phases AS
WITH d AS (
  SELECT string_split(parse_filename(log_file, true), '-')[2]::BIGINT AS job_id, message,
         string_split(string_split(message, '(')[2], ')')[1] AS inner_txt
  FROM read_duck_hunt_log('raw/joblog-*.txt', 'regexp:(?P<message>Duration \S+ .*)')
  WHERE contains(message, 'transform'))
SELECT job_id,
       rtrim(string_split(trim(string_split(string_split(message, '(')[1], ' ')[-2]), 's')[1], 's')::DOUBLE AS wall_s,
       map_from_entries(list_transform(string_split(inner_txt, ', '),
         x -> {k: string_split(x, ' ')[1], v: rtrim(string_split(x, ' ')[2], 's')::DOUBLE})) AS phase_s
FROM d;

-- gha_steps — when did each step start, and how long did it run, from the log alone? A step opens with
-- "##[group]Run <command>" and ends where the next one opens, or at "Post job cleanup." for the last one.
-- The jobs API's steps array is exact and named; use this when only the log is at hand. (The workflow
-- parser, read_duck_hunt_workflow_log, labels most per-job-log steps "Unnamed Step" — see SKILL.md Learned.)
-- verified 2026-09-23, run 35831860669 Backend Tests Shard 1: "Run uv run pytest …" 566.6 s; the API says 566 s.
CREATE OR REPLACE VIEW gha_steps AS
WITH g AS (
  SELECT string_split(parse_filename(log_file, true), '-')[2]::BIGINT AS job_id,
         right(error_code, 28)::TIMESTAMP AS ts, replace(message, '##[group]', '') AS step
  FROM read_duck_hunt_log('raw/joblog-*.txt', 'regexp:(?P<code>\S+Z) (?P<message>##\[group\]Run .*|Post job cleanup\.)')
  WHERE error_code <> ''),
s AS (SELECT *, date_diff('millisecond', ts, lead(ts) OVER (PARTITION BY job_id ORDER BY ts)) / 1000.0 AS seconds FROM g)
SELECT job_id, row_number() OVER (PARTITION BY job_id ORDER BY ts) AS n, step, ts AS started_at, seconds
FROM s WHERE starts_with(step, 'Run ');

-- gha_errors — which ##[error] annotations did each job raise? fingerprint (a hash of the normalized message,
-- stable across calls) groups the same error across jobs and runs.
-- verified 2026-09-23 on 5 failed inframe jobs: all 5 "Process completed with exit code 1.", one fingerprint.
CREATE OR REPLACE VIEW gha_errors AS
SELECT string_split(parse_filename(log_file, true), '-')[2]::BIGINT AS job_id,
       right(error_code, 28)::TIMESTAMP AS ts, message, fingerprint, log_line_start
FROM read_duck_hunt_log('raw/joblog-*.txt', 'regexp:(?P<code>\S+Z) ##\[error\](?P<message>.*)')
WHERE error_code <> '';

-- biome_diagnostics — which lint rules fired where, and which one failed the job? Biome prints
-- "path:line:col lint/<group>/<rule> ━━━" and, two lines on, "× msg" for an error or "! msg" for a warning;
-- context := 3 brings those lines along.
-- verified 2026-09-23, failed Frontend Checks 105026238565: plays.test.ts:515 lint/correctness/noUnsafeOptionalChaining is the error.
CREATE OR REPLACE VIEW biome_diagnostics AS
SELECT string_split(parse_filename(log_file, true), '-')[2]::BIGINT AS job_id,
       ref_file AS file, ref_line AS line, error_code AS rule,
       len(list_filter(context, x -> contains(x.content, '  × '))) > 0 AS is_error,
       list_filter(context, x -> NOT x.is_event) AS around
FROM read_duck_hunt_log('raw/joblog-*.txt', 'regexp:(?P<message>\S+Z) (?P<file>src/\S+):(?P<line>\d+):\d+ (?P<code>[a-z]+/\S+)', context := 3)
WHERE ref_file <> '';

-- failure_clusters — which error messages repeat, and in which jobs? Groups gha_errors by fingerprint.
-- pattern_id is renumbered on every call: never join on it; fingerprint is the cross-run key.
-- verified 2026-09-23: 1 cluster, 5 jobs, 3 runs.
CREATE OR REPLACE VIEW failure_clusters AS
SELECT fingerprint, array_agg(DISTINCT job_id) AS job_ids, len(job_ids) AS n_jobs, array_agg(message)[1] AS example
FROM gha_errors GROUP BY fingerprint ORDER BY n_jobs DESC;

-- recurring_diagnostics — which lint finding recurs across jobs (and so across runs)? Keyed on rule + file,
-- because a diagnostic's line moves between commits. Join job_id to the jobs API for run and branch.
-- verified 2026-09-23: noArrayIndexKey and noNonNullAssertion recur in all 3 failed Frontend Checks logs.
CREATE OR REPLACE VIEW recurring_diagnostics AS
SELECT rule, file, array_agg(DISTINCT job_id) AS job_ids, len(job_ids) AS n_jobs,
       array_agg(line ORDER BY job_id) AS lines, bool_or(is_error) AS ever_error
FROM biome_diagnostics GROUP BY rule, file HAVING len(array_agg(DISTINCT job_id)) > 1 ORDER BY n_jobs DESC, rule;

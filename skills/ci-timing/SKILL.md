---
name: ci-timing
description: >
  GitHub Actions timing as tables — where CI minutes go, read from GitHub so anyone with `gh`
  access can re-run it. `gh run list/view --json` and `gh api` (a PR's files, a run's log zip)
  through shellfs, every response landed under raw/ with a UTC timestamp, then runs / jobs /
  steps / PR-files tables and the questions that matter: the long pole, setup vs suite inside a
  job, whether the change-detection gate runs jobs a PR did not need, and whether test shards
  are balanced. Use when asked why CI is slow, what a run spent its time on, for a CI or PR
  review page, or for any timing evidence a teammate may see — never from local logs. Worked
  example: ~/inframe/internal/ci/duckdb/ (review.sql, slow.sql).
argument-hint: "<owner/repo> [workflow] [question]"
allowed-tools: Bash, mcp__dev__ci_hunt, mcp__dev__query
---

Read `/duckstack:duck` first; its process rules apply. Test-level timing inside a job comes
from the log through `/duckstack:duck-hunt`; the page is `/duckstack:one-pager`. This skill is
the GitHub half: which runs, which jobs, which steps, which files.

**Evidence a teammate may see reads from GitHub, not from this laptop.** A query over local
logfiles or session transcripts cannot be handed to anyone. Everything below needs only
`gh auth status` on the repo.

## 1. Fetch — shellfs, raw/ first, never overwritten

```sql
INSTALL shellfs FROM community; LOAD shellfs;
-- read_json(path, format := 'auto', records := 'auto', columns := NULL, maximum_depth := -1,
--           sample_size := 20480, ignore_errors := false, filename := false, ...)

-- the last 200 runs of every workflow
CREATE OR REPLACE TEMP TABLE fetch_runs AS
FROM read_json('ts=$(date -u +%Y%m%dT%H%M%SZ); gh run list --repo <o>/<r> --limit 200 --json attempt,conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,name,number,startedAt,status,updatedAt,url,workflowName | tee raw/runs-$ts.json |');

-- jobs and steps of the last 40 runs of one workflow: one `gh run view` per run
CREATE OR REPLACE TEMP TABLE fetch_jobs AS
FROM read_json('ts=$(date -u +%Y%m%dT%H%M%SZ); gh run list --repo <o>/<r> --workflow ci.yml --limit 40 --json databaseId --jq ''.[].databaseId'' | xargs -I{} gh run view {} --repo <o>/<r> --json databaseId,jobs | tee raw/jobs-$ts.json |', format := 'unstructured');

-- the files each run's PR changes (the gate question): one JSON object per line
CREATE OR REPLACE TEMP TABLE fetch_prfiles AS
FROM read_json('ts=$(date -u +%Y%m%dT%H%M%SZ); gh run list --repo <o>/<r> --workflow ci.yml --limit 40 --json databaseId,headSha,event --jq ''.[] | "\(.databaseId) \(.headSha) \(.event)"'' | while read id sha ev; do pr=$(gh api "repos/<o>/<r>/commits/$sha/pulls" --jq ''.[0].number''); if [ -n "$pr" ]; then gh api --paginate "repos/<o>/<r>/pulls/$pr/files?per_page=100" --jq ".[] | {run_id: $id, event: \"$ev\", pr: $pr, filename: .filename}"; else echo "{\"run_id\": $id, \"event\": \"$ev\", \"pr\": null, \"filename\": null}"; fi; done | tee raw/prfiles-$ts.json |', format := 'newline_delimited');

-- one run's full log zip, for duck_hunt: fetched once, kept
-- read_csv(path, header, delim, columns, ...) over a command whose only job is to land the file
CREATE OR REPLACE TEMP TABLE fetch_zip AS
FROM read_csv('[ -s raw/run-<id>.zip ] || gh api repos/<o>/<r>/actions/runs/<id>/logs > raw/run-<id>.zip; ls -l raw/run-<id>.zip |',
              header := false, delim := '\t', columns := {line: 'VARCHAR'});
```

- `gh api --paginate` prints one JSON array per page, concatenated: read with
  `format := 'unstructured'` and `unnest(json)`.
- The bash lives in the shellfs string. No `.sh` file, no Python.
- A run's zip is `{N}_{job name}.txt` per job — the input to `/duckstack:duck-hunt`, or to the
  dev MCP's `ci_hunt(zip, glob, format)`.

## 2. Raw views, then tables — newest copy per key wins

```sql
CREATE OR REPLACE VIEW raw_runs     AS FROM read_json('raw/runs-*.json', filename := true);
CREATE OR REPLACE VIEW raw_jobs     AS FROM read_json('raw/jobs-*.json', format := 'unstructured', filename := true);
CREATE OR REPLACE VIEW raw_prfiles  AS FROM read_json('raw/prfiles-*.json', format := 'newline_delimited', filename := 'raw_file');  -- the rows carry their own `filename`

CREATE OR REPLACE TABLE runs AS
SELECT * EXCLUDE (filename),
       date_diff('second', createdAt, startedAt) AS queue_s,
       date_diff('second', startedAt, updatedAt) AS wall_s
FROM raw_runs
QUALIFY row_number() OVER (PARTITION BY databaseId ORDER BY filename DESC) = 1;

CREATE OR REPLACE TABLE jobs AS
SELECT databaseId AS run_id, unnest(j),
       date_diff('second', j.startedAt, j.completedAt) AS job_s
FROM raw_jobs, unnest(jobs) AS t(j)
QUALIFY row_number() OVER (PARTITION BY j.databaseId ORDER BY filename DESC) = 1;

CREATE OR REPLACE TABLE steps AS
SELECT run_id, databaseId AS job_id, name AS job_name, unnest(s),
       date_diff('second', s.startedAt, s.completedAt) AS step_s
FROM jobs, unnest(steps) AS t(s);
```

Verified 2026-09-22 on inframe-risk/inframe raw/: 201 runs, 41 CI runs, 540 jobs.

**Keep every job row; decide in the page view.** What the table holds, measured:

| status | conclusion | job_s |
|---|---|---|
| `completed` | `success` | real seconds (458 jobs) |
| `completed` | `skipped` | 0, or **negative** (`completedAt` before `startedAt`, 31 of 80) |
| `in_progress` | `''` — **empty string, not NULL** | `completedAt = 0001-01-01` → about **−63.9 billion** |

So a page view that timing depends on filters `status = 'completed' AND conclusion NOT IN ('', 'skipped')`
— `conclusion IS NOT NULL` lets the in-progress job through.

## 3. The questions

**Where the minutes go (the long pole).** A workflow finishes no sooner than its slowest job.
Per job, keep the sorted list and read the median and the worst off it:

```sql
SELECT name, array_agg(job_s ORDER BY job_s) AS job_s_sorted, len(job_s_sorted) AS n,
       job_s_sorted[(n + 1) // 2] AS median_s, job_s_sorted[-1] AS longest_s
FROM jobs WHERE status = 'completed' AND conclusion NOT IN ('', 'skipped')
GROUP BY name ORDER BY median_s DESC;
```

A timeline (Gantt) of one run is each job's offset from the run's first job start —
`date_diff('second', first_value(startedAt) OVER (PARTITION BY run_id ORDER BY startedAt), startedAt)` — plus its `job_s`.

**Setup vs suite.** Inside the long-pole job, `steps` in `number` order: checkout, toolchain,
dependency install, the test step, the aggregate. The test step is the suite; everything else is
setup a cache or a smaller image can win back.

**The change-detection gate.** Join `raw_prfiles` to the runs and classify each PR by where its
files live; a PR that only touches one side but ran the other side's jobs paid for nothing:

```sql
SELECT run_id, pr,
       coalesce(array_agg(filename) FILTER (WHERE starts_with(filename, 'platform/backend/')),  []) AS backend_files,
       coalesce(array_agg(filename) FILTER (WHERE starts_with(filename, 'platform/frontend/')), []) AS frontend_files,
       array_agg(filename) AS files
FROM raw_prfiles GROUP BY ALL;
-- verified: run 35796637550 (PR #1366) → 0 backend, 4 frontend files; a FILTER over no rows is NULL, hence coalesce
```

(In inframe, `.github/workflows/ci.yml` has one `changes.outputs.platform` flag gating backend
and frontend jobs together.) The saving of a split gate is the other side's job seconds on
every one-sided run.

**Shard balance.** `pytest --splits N` (pytest-split) balances by the durations recorded in
`.test_durations`; a test missing from that file counts as the average, so a stale or absent file
drifts toward a split by count. Check which of the tests that ran it covers. The evidence is per-shard
worker-seconds from the log (`/duckstack:duck-hunt`, per-test time from the Actions
timestamps) set beside each shard's `job_s`. vitest shards read the same way with the per-file
reader.

## 4. The worked example

`~/inframe/internal/ci/duckdb/` in the inframe repo:

- `review.sql` → `review.html` — open PRs with their check rollup, branches pushed without a
  PR, CI wall time by workflow, job time across the last 40 CI runs.
- `slow.sql` → `slow.html` — one green staging run: jobs, the steps inside the long pole, the
  slowest backend tests and test files, timeout plateaus, per-shard test time.

Run from that folder: `duckdb :memory: -c ".read slow.sql" && open slow.html`. `raw/` is
gitignored and grows with every run; the tables are rebuilt from it alone.

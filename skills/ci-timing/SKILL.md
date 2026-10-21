---
name: ci-timing
description: >
  GitHub Actions timing as tables — where CI minutes go, read from GitHub so anyone with `gh`
  access can re-run it. `gh run list/view --json` and `gh api` (a PR's files, a run's log zip)
  through shellfs, every response landed under raw/ with a UTC timestamp, then runs / jobs /
  steps / PR-files views and the questions that matter: the long pole, setup vs suite inside a
  job, whether the change-detection gate runs jobs a PR did not need, and whether test shards
  are balanced. It is the CI/CD analysis: test-level times and failures come from the job logs
  through duck-hunt's recipe views, and live-page renders the result. Use when asked why CI is
  slow, what a run or shard spends its time on, for a CI or PR review page, a brief page on one
  CI finding, or any timing evidence a teammate may see. Never use local logs. Worked examples:
  ~/inframe/internal/ci/duckdb/ (review.sql, slow.sql) and the INF-1390 shard brief (§5).
argument-hint: "<owner/repo> [workflow] [question]"
allowed-tools: Bash, mcp__dev__query
---

Read `/duckstack:duck` first; its process rules apply. This skill is the GitHub half of a CI/CD
analysis: which runs, which jobs, which steps, which files. Test-level timing and failures come from
the job logs through the recipe views in `/duckstack:duck-hunt` (`recipes.sql`). Render the page
with `/duckstack:live-page`. After an analysis, add each new log reading to those recipes and each
new gotcha to duck-hunt's Learned list.

**Evidence a teammate may see reads from GitHub, not from this laptop.** A query over local
logfiles or session transcripts cannot be handed to anyone. Everything below needs only
`gh auth status` on the repo. **Measure execution, not waiting.** Use a job's
`started_at → completed_at`, which excludes queueing and approvals. Never make run wall-clock
(`createdAt → updatedAt`) the headline.

## 1. Fetch — shellfs, raw/ first, never overwritten

```sql
INSTALL shellfs FROM community;
LOAD shellfs;

-- the last 200 runs of every workflow, landed in raw/ as they are read
SELECT * FROM read_json($cmd$gh run list --repo <owner>/<repo> --limit 200 --json attempt,conclusion,createdAt,databaseId,displayTitle,event,headBranch,headSha,name,number,startedAt,status,updatedAt,url,workflowName | tee raw/runs-$(date -u +%Y%m%dT%H%M%SZ).json |$cmd$);
```

Jobs and steps of the last 40 runs of one workflow: the run list is stage 1, one `gh run view` per
run is stage 2, rendered from each stage-1 receipt row. Stage 1 carries every value stage 2 needs.

```sql
WITH intent AS (
    SELECT '<owner>/<repo>' AS repo, 'ci.yml' AS workflow, 40 AS run_limit, 'raw' AS raw_dir,
           strftime(now(), '%Y%m%dT%H%M%SZ') AS ts
), runs_rendered AS (
    SELECT tera_render($tera$
        SELECT '{{ repo }}' AS repo, '{{ raw_dir }}' AS raw_dir, '{{ ts }}' AS ts, databaseId AS run_id
        FROM read_json($cmd$gh run list --repo {{ repo }} --workflow {{ workflow }} --limit {{ run_limit }} --json databaseId |$cmd$)
    $tera$, intent::JSON, autoescape := false) AS sql
    FROM intent
), runs_dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM runs_rendered
), jobs_rendered AS (
    SELECT tera_render($tera$
        SELECT databaseId, len(jobs) AS job_count
        FROM read_json($cmd$gh run view {{ run_id }} --repo {{ repo }} --json databaseId,jobs | tee {{ raw_dir }}/jobs-{{ run_id }}-{{ ts }}.json |$cmd$)
    $tera$, run_row, autoescape := false) AS sql
    FROM runs_dispatched CROSS JOIN UNNEST(receipts) AS r(receipt) CROSS JOIN UNNEST(receipt.body::JSON[]) AS j(run_row)
), jobs_dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM jobs_rendered
)
SELECT receipt.* FROM jobs_dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);
```

The files each run's PR changes (the gate question): runs, then each run's PR, then that PR's
files, each stage rendered from the last one's receipts, and the rows come back in the last
stage's receipts: every row carries `run_id`, `event`, `pr`, `filename` and GitHub's whole file
object as `pr_file`, and stage 3 tees GitHub's response into raw/. A run with no PR returns no rows
at stage 2 and sends nothing at stage 3. §3 reads it as the view `pr_files`
(`CREATE OR REPLACE VIEW pr_files AS` in front).

```sql
WITH intent AS (
    SELECT '<owner>/<repo>' AS repo, 'ci.yml' AS workflow, 40 AS run_limit
), runs_rendered AS (
    SELECT tera_render($tera$
        SELECT '{{ repo }}' AS repo, databaseId AS run_id, headSha AS head_sha, event
        FROM read_json($cmd$gh run list --repo {{ repo }} --workflow {{ workflow }} --limit {{ run_limit }} --json databaseId,headSha,event |$cmd$)
    $tera$, intent::JSON, autoescape := false) AS sql
    FROM intent
), runs_dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM runs_rendered
), prs_rendered AS (
    SELECT tera_render($tera$
        SELECT '{{ repo }}' AS repo, {{ run_id }} AS run_id, '{{ event }}' AS event, pull.number AS pr
        FROM read_json($cmd$gh api --paginate --slurp repos/{{ repo }}/commits/{{ head_sha }}/pulls |$cmd$)
        CROSS JOIN UNNEST(json) AS page(pull)
    $tera$, run_row, autoescape := false) AS sql
    FROM runs_dispatched CROSS JOIN UNNEST(receipts) AS r(receipt) CROSS JOIN UNNEST(receipt.body::JSON[]) AS j(run_row)
), prs_dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM prs_rendered
), files_rendered AS (
    SELECT tera_render($tera$
        SELECT {{ run_id }} AS run_id, '{{ event }}' AS event, {{ pr }} AS pr, file.*
        FROM read_json($cmd$gh api --paginate --slurp "repos/{{ repo }}/pulls/{{ pr }}/files?per_page=100" | tee raw/prfiles-{{ run_id }}-{{ pr }}.json |$cmd$)
        CROSS JOIN UNNEST(json) AS page(file)
    $tera$, pr_row, autoescape := false) AS sql
    FROM prs_dispatched CROSS JOIN UNNEST(receipts) AS r(receipt) CROSS JOIN UNNEST(receipt.body::JSON[]) AS j(pr_row)
), files_dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM files_rendered
)
SELECT (file ->> 'run_id')::BIGINT AS run_id, file ->> 'event' AS event, (file ->> 'pr')::BIGINT AS pr,
       file ->> 'filename' AS filename, file AS pr_file
FROM files_dispatched CROSS JOIN UNNEST(receipts) AS r(receipt) CROSS JOIN UNNEST(receipt.body::JSON[]) AS f(file);
-- verified 2026-10-21 on inframe-risk/inframe, 6 runs: the same rows as the filename-only version, every field kept
```

One run's full log zip, for duck_hunt: fetched once, kept. The command's only job is to land the
file; its `ls -l` line is the receipt.

```sql
SELECT * FROM read_lines($cmd${ [ -s raw/run-<run_id>.zip ] || gh api repos/<owner>/<repo>/actions/runs/<run_id>/logs > raw/run-<run_id>.zip; } && ls -l raw/run-<run_id>.zip |$cmd$);
```

- `gh api --paginate --slurp` over a list endpoint gives one row per page with a `json` list
  column: `CROSS JOIN UNNEST(json)`. Select `file.filename` from it, not a bare `filename`, which
  binds to the reader's own filename column when the page has none. An empty list is one empty
  page and unnests to no rows; a bare `gh api` of `[]` has no columns and fails to bind (a commit
  with no PR, measured 2026-10-21).
- One command per row, dispatched. No loop in the shellfs string, no `.sh` file, no Python.
- A run's zip is `{N}_{job name}.txt` per job — the input to `/duckstack:duck-hunt`
  (`read_duck_hunt_log('zip://<zip>/<glob>', format)` on dev).

## 2. Views over raw/ — newest copy per key wins

```sql
CREATE OR REPLACE VIEW raw_runs     AS FROM read_json('raw/runs-*.json', filename := true);
CREATE OR REPLACE VIEW raw_jobs     AS FROM read_json('raw/jobs-*.json', format := 'unstructured', filename := true);

CREATE OR REPLACE VIEW runs AS
SELECT * EXCLUDE (filename),
       date_diff('second', createdAt, startedAt) AS queue_s,
       date_diff('second', startedAt, updatedAt) AS wall_s
FROM raw_runs
QUALIFY row_number() OVER (PARTITION BY databaseId ORDER BY filename DESC) = 1;

CREATE OR REPLACE VIEW jobs AS
SELECT databaseId AS run_id, j.*,
       date_diff('second', j.startedAt, j.completedAt) AS job_s
FROM raw_jobs CROSS JOIN UNNEST(jobs) AS t(j)
QUALIFY row_number() OVER (PARTITION BY j.databaseId ORDER BY filename DESC) = 1;

CREATE OR REPLACE VIEW steps AS
SELECT run_id, databaseId AS job_id, name AS job_name, s.*,
       date_diff('second', s.startedAt, s.completedAt) AS step_s
FROM jobs CROSS JOIN UNNEST(steps) AS t(s);
```

Verified 2026-09-22 on inframe-risk/inframe raw/: 201 runs, 41 CI runs, 540 jobs; the view
bodies re-checked 2026-10-17 on per-run `jobs-<run_id>-<ts>.json` files (2 CI runs).

**Keep every job row; decide in the page view.** What the view holds, measured:

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

**The change-detection gate.** Join `pr_files` (§1) to the runs and classify each PR by where its
files live; a PR that only touches one side but ran the other side's jobs paid for nothing:

```sql
SELECT run_id, pr,
       list_filter(array_agg(filename), f -> starts_with(f, 'platform/backend/'))  AS backend_files,
       list_filter(array_agg(filename), f -> starts_with(f, 'platform/frontend/')) AS frontend_files,
       array_agg(filename) AS files
FROM pr_files GROUP BY ALL;
-- verified 2026-10-17: run 39075670966 (PR #1662) → 9 backend, 0 frontend of 14 files; no match is [], not NULL
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

Run from that folder: `duckdb :memory: -f slow.sql && open slow.html`. `raw/` is
gitignored and grows with every run; the tables are rebuilt from it alone.

## 5. A brief finding page (the INF-1390 shard brief, 2026-09-23)

The shape for one finding, such as "every PR waits on Backend Tests Shard 1":

1. **Scope the runs with gh**: `gh run list --workflow ci.yml --user <login> --created ">=<date>"`,
   then `gh api …/actions/runs/{id}/jobs?per_page=100` per run as a self-dispatched stage (§1),
   one `raw/jobs-<run_id>-<ts>.json` each. Read them with `read_json(…, format := 'unstructured')`,
   then `CROSS JOIN UNNEST(jobs)`.
2. **A view, not a table**, so a live page re-fetches. Gate the fetch in SQL: the newest
   `raw/jobs-*.json` modified time comes from hostfs `ls`, and the fetch is rendered only `WHERE`
   it is over 30 minutes old, so a fresh file sends nothing.
3. **Keep only runs with the usual layout.** Count shard jobs per run: experiment branches run
   other shard counts, and their shard 1 is not the same job.
4. **Per job:** `array_agg(job_s ORDER BY job_s)`, the median read off that list, and the median
   run's `html_url` for the link. Keep every point for a strip chart.
5. **Typical run:** the one whose wall is nearest the median wall. Land its shard logs as
   `raw/joblog-<job_id>.txt` and read them with the duck-hunt recipe views; a landed log never
   changes, so it is fetched once.
6. **Room for "after":** `after_since` (the fix's merge time) is a value in the first CTE, and
   runs started after it get `series = 'after'`. The charts draw the after bar only when it has rows.
7. **The cause, from git:** `.test_durations` read with duck_tails (`read_text('git:///…@origin/staging')`,
   `json_keys`), and its age from `git_blame` (newest `author_date`). Coverage is a `LEFT JOIN`
   of the tests that ran against its keys.

What it found: shard 1 had a median of 9m 43s against 5m 45s–7m 04s for the other shards.
`.test_durations` was last written 2026-06-12 and covered 28% of 19,248 tests. 69% of shard 1's
worker time was in tests it had no entry for.

## Portable readers

`references/github_run.sql` (one run, every API field) and `references/github_jobs.sql` (every
jobs page, steps nested) run with only `gh` and the pinned CLI; see `docs/portable-readers.md`.

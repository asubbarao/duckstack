-- luna_ci/handler.sql: the body of POST /luna/ci-fix (routes/luna_ci.sql). Per request the route replaces the request
-- id placeholder and the base64 body placeholder, then posts this text to /sql, so an edit here is live on the next request.
-- Body: {"repo": "owner/name", "number": 18, "source": "cron:open_prs", "jobs": ["<actions job url>"], "task": "..."};
-- repo and number are required. Rules: open PR by asubbarao, head on the asubbarao fork, never inframe-risk/*,
-- one dispatch per head sha ever (primary key), no second Luna on a PR while one runs, at most 5 running.
-- Every request is a row in luna_ci_requests with its decision; every launch is a row in luna_ci_dispatch; shell receipts in luna_ci_receipts.
-- Raw files per request: ~/.duck/raw/luna_ci/<rid>/ (lookup.sh, pr.json, launch.sh); per run: ~/.duck/luna_runs/
-- parent_system=devserver/parent=luna_ci/luna=<name>-<number>-<sha7>/ (brief.md, run.sh, pid, prep.log, logs/, out.md, exit).
CREATE TABLE IF NOT EXISTS luna_ci_dispatch (rid VARCHAR, source VARCHAR, repo VARCHAR, number INTEGER, head_owner VARCHAR,
    head_branch VARCHAR, head_sha VARCHAR, failing_jobs JSON, task VARCHAR, bare VARCHAR, worktree VARCHAR, run_dir VARCHAR,
    out_path VARCHAR, brief VARCHAR, run_script VARCHAR, pid BIGINT, started_at TIMESTAMPTZ, finished_at TIMESTAMPTZ,
    report VARCHAR, PRIMARY KEY (repo, number, head_sha));
CREATE TABLE IF NOT EXISTS luna_ci_requests (rid VARCHAR, received_at TIMESTAMPTZ, source VARCHAR, repo VARCHAR,
    number INTEGER, body JSON, repo_ok BOOLEAN, pr JSON, head_sha VARCHAR, jobs JSON, decision VARCHAR);
CREATE TABLE IF NOT EXISTS luna_ci_receipts (rid VARCHAR, step VARCHAR, recorded_at TIMESTAMPTZ, content VARCHAR);
INSERT INTO luna_ci_receipts BY NAME
SELECT '@RID' AS rid, 'mkdir' AS step, now() AS recorded_at, content
FROM read_text('mkdir -p /Users/aloksubbarao/.duck/raw/luna_ci/@RID && echo ok |');
-- repo is the only body field that reaches a shell, so it must be owner/name in [a-z0-9._-]; the rest stay data.
INSERT INTO luna_ci_requests BY NAME
WITH req AS (SELECT TRY_CAST(decode(from_base64('@BODY64')) AS JSON) AS b),
f AS (SELECT b, coalesce(b ->> 'source', 'unknown') AS source, b ->> 'repo' AS repo,
             TRY_CAST(b ->> 'number' AS INTEGER) AS number FROM req)
SELECT '@RID' AS rid, now() AS received_at, source, repo, number, b AS body,
       coalesce(len(string_split(repo, '/')) = 2
                AND translate(lower(repo), 'abcdefghijklmnopqrstuvwxyz0123456789._-/', '') = ''
                AND NOT starts_with(repo, '-') AND number > 0, false) AS repo_ok
FROM f;
COPY (SELECT tera_render('lookup.tera',
          json_object('repo', repo, 'number', number, 'dir', '/Users/aloksubbarao/.duck/raw/luna_ci/@RID',
                      'valid', repo_ok AND NOT starts_with(lower(repo), 'inframe-risk/')),
          autoescape := false, template_path := '__SERVER_DIR__/server/luna_ci/*.tera') AS script
      FROM luna_ci_requests WHERE rid = '@RID')
TO '/Users/aloksubbarao/.duck/raw/luna_ci/@RID/lookup.sh' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
UPDATE luna_ci_requests SET pr = d.pr, head_sha = d.head_sha, jobs = d.jobs, decision = d.decision
FROM (
  WITH r AS (SELECT * FROM luna_ci_requests WHERE rid = '@RID'),
  p AS (
    SELECT '@RID' AS rid, to_json(g) AS pr, g.state, g.author.login AS author, g.headRepositoryOwner.login AS head_owner,
           g.headRefOid AS head_sha,
           list_transform(list_filter(g.statusCheckRollup,
               x -> coalesce(x.conclusion, x.state) IN ('FAILURE', 'ERROR', 'TIMED_OUT', 'STARTUP_FAILURE', 'CANCELLED')),
               x -> {name: coalesce(x.name, x.context), conclusion: coalesce(x.conclusion, x.state),
                     url: coalesce(x.detailsUrl, x.targetUrl),
                     job_id: CASE WHEN contains(coalesce(x.detailsUrl, ''), '/actions/runs/')
                                  THEN TRY_CAST(string_split(x.detailsUrl, '/')[-1] AS BIGINT)::VARCHAR END}) AS rollup_jobs
    FROM read_json('bash /Users/aloksubbarao/.duck/raw/luna_ci/@RID/lookup.sh |', format := 'unstructured',
        columns := {url: 'VARCHAR', state: 'VARCHAR', title: 'VARCHAR', author: 'STRUCT(login VARCHAR)',
                    baseRefName: 'VARCHAR', headRefName: 'VARCHAR', headRefOid: 'VARCHAR',
                    headRepositoryOwner: 'STRUCT(login VARCHAR)', headRepository: 'STRUCT(name VARCHAR)',
                    statusCheckRollup: 'STRUCT(name VARCHAR, context VARCHAR, conclusion VARCHAR, state VARCHAR, detailsUrl VARCHAR, targetUrl VARCHAR)[]',
                    files: 'STRUCT(path VARCHAR)[]'}) AS g
  ),
  given AS (
    SELECT rid, list_transform(from_json(body -> 'jobs', '["VARCHAR"]'),
               u -> {name: 'reported by ' || source, conclusion: 'REPORTED', url: u,
                     job_id: CASE WHEN starts_with(u, 'https://github.com/' || repo || '/actions/runs/')
                                  THEN TRY_CAST(string_split(u, '/')[-1] AS BIGINT)::VARCHAR END}) AS given_jobs
    FROM r
  ),
  running AS (SELECT '@RID' AS rid, count(started_at) AS n_running FROM luna_ci_dispatch WHERE finished_at IS NULL),
  busy AS (SELECT DISTINCT repo, number, true AS pr_running FROM luna_ci_dispatch WHERE finished_at IS NULL),
  seen AS (SELECT repo, number, head_sha, true AS sha_seen FROM luna_ci_dispatch),
  j AS (
    SELECT r.rid, r.repo, r.number, r.repo_ok, p.pr, p.state, p.author, p.head_owner, p.head_sha,
           CASE WHEN len(given.given_jobs) > 0 THEN given.given_jobs ELSE p.rollup_jobs END AS job_list
    FROM r LEFT JOIN p USING (rid) LEFT JOIN given USING (rid)
  )
  SELECT j.rid, j.pr, j.head_sha, to_json(j.job_list) AS jobs,
    CASE WHEN NOT j.repo_ok THEN 'rejected: repo must be owner/name and number a positive integer'
         WHEN starts_with(lower(j.repo), 'inframe-risk/') THEN 'rejected: inframe-risk repos are excluded'
         WHEN j.pr IS NULL THEN 'rejected: gh pr view returned no PR'
         WHEN j.state IS DISTINCT FROM 'OPEN' THEN 'rejected: PR state is ' || coalesce(j.state, 'unknown')
         WHEN j.author IS DISTINCT FROM 'asubbarao' THEN 'rejected: PR author is ' || coalesce(j.author, 'unknown')
         WHEN j.head_owner IS DISTINCT FROM 'asubbarao' THEN 'rejected: head branch is not on the asubbarao fork'
         WHEN coalesce(len(j.job_list), 0) = 0 THEN 'skipped: no failing checks on the head commit'
         WHEN seen.sha_seen THEN 'skipped: already dispatched for head ' || left(j.head_sha, 7)
         WHEN busy.pr_running THEN 'skipped: a Luna is still running on this PR'
         WHEN running.n_running >= 5 THEN 'skipped: 5 Lunas already running'
         ELSE 'dispatch' END AS decision
  FROM j LEFT JOIN running USING (rid) LEFT JOIN busy USING (repo, number) LEFT JOIN seen USING (repo, number, head_sha)
) AS d
WHERE luna_ci_requests.rid = d.rid;
-- tera renders the brief and the run script (worktree prep + the codex command) from the request row.
INSERT INTO luna_ci_dispatch BY NAME
WITH r AS (
  SELECT rid, source, repo, number, head_sha, jobs, body ->> 'task' AS task,
         from_json(pr, '{"url":"VARCHAR","title":"VARCHAR","baseRefName":"VARCHAR","headRefName":"VARCHAR","headRepositoryOwner":{"login":"VARCHAR"},"headRepository":{"name":"VARCHAR"},"files":[{"path":"VARCHAR"}]}') AS g
  FROM luna_ci_requests WHERE rid = '@RID' AND decision = 'dispatch'
), paths AS (
  SELECT *, g.headRepository.name AS head_name, g.headRefName AS head_branch, g.headRepositoryOwner.login AS head_owner,
         head_name || '-' || number || '-' || left(head_sha, 7) AS slug,
         '/Users/aloksubbarao/worktrees/_bare/' || head_name || '.git' AS bare,
         '/Users/aloksubbarao/worktrees/luna-ci/' || slug AS worktree,
         '/Users/aloksubbarao/.duck/luna_runs/parent_system=devserver/parent=luna_ci/luna=' || slug AS run_dir,
         run_dir || '/out.md' AS out_path,
         'git@github-asubbarao:asubbarao/' || head_name || '.git' AS push_url
  FROM r
), ctx AS (
  SELECT *, json_object('rid', rid, 'source', source, 'repo', repo, 'number', number, 'url', g.url, 'title', g.title,
             'head_branch', head_branch, 'head_name', head_name, 'head_sha', head_sha, 'base_branch', g.baseRefName,
             'touches_ci', len(list_filter(g.files, f -> starts_with(f.path, '.github/'))) > 0,
             'jobs', jobs, 'task', task, 'worktree', worktree, 'bare', bare, 'run_dir', run_dir, 'push_url', push_url) AS context
  FROM paths
), rendered AS (
  SELECT *,
    tera_render('brief.tera', context, autoescape := false, template_path := '__SERVER_DIR__/server/luna_ci/*.tera') AS brief,
    tera_render('run.tera', context, autoescape := false, template_path := '__SERVER_DIR__/server/luna_ci/*.tera') AS run_script
  FROM ctx
)
SELECT rid, source, repo, number, head_owner, head_branch, head_sha, jobs AS failing_jobs, task, bare, worktree, run_dir,
       out_path, brief, run_script, now() AS started_at
FROM rendered;
-- One launch.sh per request writes the run folder and starts run.sh in its own session (fork + setsid): launchd kills
-- the server's process group on every restart, nohup included. It prints "<run_dir> <pid>".
COPY (SELECT tera_render('launch.tera',
          json_object('runs', coalesce(list({run_dir: run_dir, brief: brief, run_script: run_script,
                                             brief_eof: 'LUNA_BRIEF_' || md5(brief), run_eof: 'LUNA_RUN_' || md5(run_script)}),
                                       [])),
          autoescape := false, template_path := '__SERVER_DIR__/server/luna_ci/*.tera') AS script
      FROM luna_ci_dispatch WHERE rid = '@RID')
TO '/Users/aloksubbarao/.duck/raw/luna_ci/@RID/launch.sh' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
INSERT INTO luna_ci_receipts BY NAME
SELECT '@RID' AS rid, 'launch' AS step, now() AS recorded_at, content FROM read_text('bash /Users/aloksubbarao/.duck/raw/luna_ci/@RID/launch.sh 2>&1 |');
UPDATE luna_ci_dispatch SET pid = l.pid
FROM (SELECT parts[1] AS run_dir, TRY_CAST(parts[2] AS BIGINT) AS pid
      FROM (SELECT string_split(line, ' ') AS parts
            FROM luna_ci_receipts CROSS JOIN UNNEST(string_split(content, chr(10))) AS u(line)
            WHERE rid = '@RID' AND step = 'launch')) AS l
WHERE luna_ci_dispatch.rid = '@RID' AND luna_ci_dispatch.run_dir = l.run_dir;
SELECT r.rid, r.received_at, r.source, r.repo, r.number, r.head_sha, r.decision, d.run_dir, d.out_path, d.pid
FROM luna_ci_requests AS r LEFT JOIN luna_ci_dispatch AS d USING (rid)
WHERE r.rid = '@RID'

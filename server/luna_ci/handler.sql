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
-- Render one SQL launch body per dispatch row.  The body creates its run
-- directory, writes the brief with DuckDB COPY, and forks Codex detached.
-- Inputs are data: effort and sandbox are allow-listed before they reach the
-- shell, and all paths/brief text are quoted as SQL and POSIX literals.
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
    '' AS run_script
  FROM ctx
)
SELECT rid, source, repo, number, head_owner, head_branch, head_sha, jobs AS failing_jobs, task, bare, worktree, run_dir,
       out_path, brief, run_script, now() AS started_at
FROM rendered;
-- Self-dispatch exactly one complete SQL body for each input row.  A JSON POST
-- keeps the SQL body intact beyond cpp-httplib's form-body limit.
INSERT INTO luna_ci_receipts BY NAME
WITH launch_rows AS (
  SELECT d.rid, d.run_dir, d.worktree AS cwd, d.bare, d.brief,
         CASE WHEN r.body ->> 'effort' IN ('low', 'medium', 'high')
              THEN r.body ->> 'effort' ELSE 'high' END AS effort,
         CASE WHEN r.body ->> 'sandbox' IN ('read-only', 'workspace-write', 'danger-full-access')
              THEN r.body ->> 'sandbox' ELSE 'workspace-write' END AS sandbox
  FROM luna_ci_dispatch d
  JOIN luna_ci_requests r USING (rid)
  WHERE d.rid = '@RID'
), quoted AS (
  SELECT *,
         chr(39) || replace(brief, chr(39), chr(39) || chr(39)) || chr(39) AS brief_literal,
         chr(39) || replace(run_dir || '/brief.md', chr(39), chr(39) || chr(39)) || chr(39) AS brief_path_literal,
         chr(39) || replace('mkdir -p ' || run_dir, chr(39), chr(39) || chr(39)) || chr(39) AS mkdir_sql,
         chr(39) || replace(
             'perl -MPOSIX -e ' || chr(39) ||
             'my $pid = fork(); die "fork: $!" unless defined $pid; if ($pid) { print $pid; exit 0 } POSIX::setsid(); exec @ARGV or die "exec: $!";' || chr(39) ||
             ' sh -c ' || chr(39) ||
             'echo $$ > ' || chr(39) || run_dir || '/pid' || chr(39) || '; ' ||
             '/Users/aloksubbarao/.local/bin/codex exec -C ' || chr(39) || cwd || chr(39) ||
             ' --add-dir ' || chr(39) || bare || chr(39) ||
             ' -s ' || chr(39) || sandbox || chr(39) ||
             ' -c sandbox_workspace_write.network_access=true -m gpt-5.6-luna' ||
             ' -c model_reasoning_effort=' || chr(39) || effort || chr(39) ||
             ' --color never --json -o ' || chr(39) || run_dir || '/out.md' || chr(39) ||
             ' - < ' || chr(39) || run_dir || '/brief.md' || chr(39) ||
             ' > ' || chr(39) || run_dir || '/events.jsonl' || chr(39) ||
             ' 2> ' || chr(39) || run_dir || '/run.log' || chr(39) ||
             '; status=$?; echo $status > ' || chr(39) || run_dir || '/exit' || chr(39) || '; exit $status' || chr(39),
             chr(39), chr(39) || chr(39)) || chr(39) AS launch_sql
  FROM launch_rows
), rendered_launch AS (
  SELECT *, tera_render('run.tera',
      json_object('mkdir_sql', mkdir_sql, 'brief_literal', brief_literal,
                  'brief_path_literal', brief_path_literal, 'launch_sql', launch_sql),
      autoescape := false, template_path := '__SERVER_DIR__/server/luna_ci/*.tera') AS program
  FROM quoted
), posted AS (
  SELECT *, http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'},
             json_object('sql', program)) AS receipt
  FROM rendered_launch
)
SELECT rid, 'launch' AS step, now() AS recorded_at,
       json_object('status', receipt ->> '$.status', 'body', receipt ->> '$.body', 'statement', program)::VARCHAR AS content
FROM posted;
UPDATE luna_ci_dispatch SET pid = l.pid
FROM (
    SELECT rid,
           TRY_CAST(json_extract_string(json_extract_string(content, '$.body'), '$[0].content') AS BIGINT) AS pid
    FROM luna_ci_receipts
    WHERE rid = '@RID' AND step = 'launch'
) l
WHERE luna_ci_dispatch.rid = l.rid AND l.pid IS NOT NULL;
SELECT r.rid, r.received_at, r.source, r.repo, r.number, r.head_sha, r.decision, d.run_dir, d.out_path, d.pid
FROM luna_ci_requests AS r LEFT JOIN luna_ci_dispatch AS d USING (rid)
WHERE r.rid = '@RID'

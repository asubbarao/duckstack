-- open_prs.sql: why each open PR by asubbarao is sitting, and whose move it is. Rebuilt by cron.sql each hour;
-- read with: FROM open_prs_waiting ORDER BY whose_move, idle_days DESC.
-- Each run keeps the previous rows in open_prs_previous, diffs them into open_prs_changes, and posts the changed
-- PRs as one JSON payload to the agent inbox (POST /inbox, read as agent_inbox); receipts in open_prs_inbox_receipts.
CREATE TABLE IF NOT EXISTS open_prs_waiting (checked_at TIMESTAMPTZ, whose_move VARCHAR, idle_days BIGINT, repo VARCHAR,
    number INTEGER, title VARCHAR, ci VARCHAR, base_ci VARCHAR, mergeable VARCHAR, last_reviewer VARCHAR);
CREATE OR REPLACE TABLE open_prs_previous AS FROM open_prs_waiting;
CREATE OR REPLACE TABLE open_prs_waiting AS
WITH raw AS (
  SELECT CASE WHEN (content::JSON -> '$.data.search.nodes') IS NULL THEN error('open_prs: gh returned no search nodes: ' || left(content, 300))
              ELSE content::JSON -> '$.data.search.nodes' END AS nodes
  FROM read_text($cmd$GH_TOKEN=$(gh auth token --user asubbarao) gh api graphql -f query='{ search(query:"author:asubbarao is:pr is:open", type:ISSUE, first:100){ nodes{ ... on PullRequest { url number title createdAt reviewDecision mergeable repository{nameWithOwner defaultBranchRef{target{... on Commit{statusCheckRollup{state contexts(first:100){nodes{... on CheckRun{name conclusion} ... on StatusContext{context state}}}}}}}} files(first:100){nodes{path}} commits(last:1){nodes{commit{committedDate statusCheckRollup{state contexts(first:100){nodes{... on CheckRun{name conclusion} ... on StatusContext{context state}}}}}}} reviews(last:10){nodes{author{login} state submittedAt}} comments(last:10){nodes{author{login} createdAt}} reviewThreads(last:50){nodes{isResolved comments(last:1){nodes{author{login} createdAt}}}} } } } }'|$cmd$)
), pr AS (
  SELECT p.* FROM (SELECT unnest(from_json(nodes, '[{"url":"VARCHAR","number":"INTEGER","title":"VARCHAR","createdAt":"TIMESTAMP","reviewDecision":"VARCHAR","mergeable":"VARCHAR","repository":{"nameWithOwner":"VARCHAR","defaultBranchRef":{"target":{"statusCheckRollup":{"state":"VARCHAR","contexts":{"nodes":[{"name":"VARCHAR","conclusion":"VARCHAR","context":"VARCHAR","state":"VARCHAR"}]}}}}},"files":{"nodes":[{"path":"VARCHAR"}]},"commits":{"nodes":[{"commit":{"committedDate":"TIMESTAMP","statusCheckRollup":{"state":"VARCHAR","contexts":{"nodes":[{"name":"VARCHAR","conclusion":"VARCHAR","context":"VARCHAR","state":"VARCHAR"}]}}}}]},"reviews":{"nodes":[{"author":{"login":"VARCHAR"},"state":"VARCHAR","submittedAt":"TIMESTAMP"}]},"comments":{"nodes":[{"author":{"login":"VARCHAR"},"createdAt":"TIMESTAMP"}]},"reviewThreads":{"nodes":[{"isResolved":"BOOLEAN","comments":{"nodes":[{"author":{"login":"VARCHAR"},"createdAt":"TIMESTAMP"}]}}]}}]')) AS p
  FROM raw)
), events AS (
  SELECT url, r.author.login AS who, r.submittedAt AS ts FROM pr CROSS JOIN UNNEST(pr.reviews.nodes) AS t(r)
  UNION ALL SELECT url, c.author.login, c.createdAt FROM pr CROSS JOIN UNNEST(pr.comments.nodes) AS t(c)
  UNION ALL SELECT url, th.comments.nodes[-1].author.login, th.comments.nodes[-1].createdAt FROM pr CROSS JOIN UNNEST(pr.reviewThreads.nodes) AS t(th)
), humans AS (
  SELECT url, who, ts, who IN ('asubbarao', 'asubbarao-ifr') AS mine
  FROM events
  WHERE who NOT LIKE '%[bot]' AND who NOT IN ('coderabbitai', 'github-actions', 'codecov')
), per_pr AS (
  SELECT url,
         max(ts) FILTER (WHERE mine) AS my_last,
         max(ts) FILTER (WHERE NOT mine) AS their_last,
         arg_max(who, ts) FILTER (WHERE NOT mine) AS their_who
  FROM humans GROUP BY url
), threads AS (
  SELECT url, sum((NOT th.isResolved)::INT) AS open_threads
  FROM pr CROSS JOIN UNNEST(pr.reviewThreads.nodes) AS t(th) GROUP BY url
), checks AS (
  -- Failing check names on the PR head and on the default branch head; a CheckRun has conclusion, a StatusContext state.
  SELECT url,
         list_transform(list_filter(pr.commits.nodes[-1].commit.statusCheckRollup.contexts.nodes,
             c -> coalesce(c.conclusion, c.state) IN ('FAILURE', 'ERROR', 'TIMED_OUT', 'STARTUP_FAILURE')), c -> coalesce(c.name, c.context)) AS pr_failing,
         list_transform(list_filter(pr.repository.defaultBranchRef.target.statusCheckRollup.contexts.nodes,
             c -> coalesce(c.conclusion, c.state) IN ('FAILURE', 'ERROR', 'TIMED_OUT', 'STARTUP_FAILURE')), c -> coalesce(c.name, c.context)) AS base_failing,
         len(list_filter(pr.files.nodes, f -> starts_with(f.path, '.github/'))) > 0 AS touches_ci
  FROM pr
), joined AS (
  SELECT pr.repository.nameWithOwner AS repo, pr.number, pr.title, pr.url, pr.reviewDecision AS decision, pr.mergeable,
         pr.commits.nodes[-1].commit.statusCheckRollup.state AS ci,
         pr.repository.defaultBranchRef.target.statusCheckRollup.state AS base_ci,
         -- Red only on checks that are already red on the default branch, and the PR does not change CI itself.
         len(checks.pr_failing) > 0 AND len(list_filter(checks.pr_failing, n -> NOT list_contains(checks.base_failing, n))) = 0
             AND NOT checks.touches_ci AS red_inherited,
         pr.commits.nodes[-1].commit.committedDate AS last_push,
         greatest(per_pr.my_last, pr.commits.nodes[-1].commit.committedDate) AS my_move,
         per_pr.their_last, per_pr.their_who, coalesce(threads.open_threads, 0) AS open_threads
  FROM pr LEFT JOIN per_pr USING (url) LEFT JOIN threads USING (url) LEFT JOIN checks USING (url)
)
SELECT now() AS checked_at,
  CASE
    WHEN decision = 'CHANGES_REQUESTED' THEN 'mine: changes requested'
    WHEN their_last > my_move THEN 'mine: reply to ' || their_who
    WHEN open_threads > 0 THEN 'mine: unresolved threads'
    WHEN ci IN ('FAILURE', 'ERROR') AND NOT red_inherited THEN 'mine: CI red'
    WHEN mergeable = 'CONFLICTING' THEN 'mine: merge conflict'
    WHEN ci IN ('FAILURE', 'ERROR') THEN 'theirs: base branch CI already red'
    WHEN decision = 'APPROVED' THEN 'theirs: approved, needs merge'
    WHEN repo LIKE 'asubbarao/%' THEN 'mine: own repo, review and merge'
    WHEN their_last IS NULL THEN 'theirs: never reviewed'
    ELSE 'theirs: waiting after my reply'
  END AS whose_move,
  date_diff('day', greatest(my_move, their_last), (now() AT TIME ZONE 'UTC')) AS idle_days,
  repo, number, title, ci, base_ci, mergeable, their_who AS last_reviewer
FROM joined
ORDER BY whose_move, idle_days DESC;
-- What changed since the previous run: opened, closed, whose_move moved, or a "mine" PR crossing 3 idle days.
CREATE OR REPLACE TABLE open_prs_changes AS
WITH j AS (
  SELECT coalesce(cur.repo, prev.repo) AS repo, coalesce(cur.number, prev.number) AS number,
         coalesce(cur.title, prev.title) AS title, cur.whose_move, prev.whose_move AS previous_whose_move,
         cur.idle_days, prev.idle_days AS previous_idle_days, cur.ci, cur.base_ci, cur.mergeable, cur.last_reviewer,
         list_filter([
           CASE WHEN prev.number IS NULL THEN 'opened' END,
           CASE WHEN cur.number IS NULL THEN 'closed' END,
           CASE WHEN cur.whose_move IS DISTINCT FROM prev.whose_move AND cur.number IS NOT NULL AND prev.number IS NOT NULL
                THEN 'whose_move changed' END,
           CASE WHEN starts_with(cur.whose_move, 'mine') AND cur.idle_days >= 3 AND coalesce(prev.idle_days, 0) < 3
                THEN 'your move, idle 3+ days' END
         ], x -> x IS NOT NULL) AS changes
  FROM open_prs_waiting AS cur FULL OUTER JOIN open_prs_previous AS prev ON cur.repo = prev.repo AND cur.number = prev.number
)
SELECT now() AS diffed_at, * FROM j WHERE len(changes) > 0;
-- One post per run, only when something changed.
CREATE TABLE IF NOT EXISTS open_prs_inbox_receipts (posted_at TIMESTAMPTZ, prs BIGINT, receipt JSON);
INSERT INTO open_prs_inbox_receipts BY NAME
SELECT now() AS posted_at, len(prs) AS prs,
       http_post('http://127.0.0.1:9495/inbox', MAP {'Content-Type': 'application/json'},
                 json_object('source', 'open_prs', 'kind', 'open_prs.changed', 'checked_at', now(), 'prs', prs)) AS receipt
FROM (SELECT list(c ORDER BY c.repo, c.number) AS prs FROM open_prs_changes AS c)
WHERE len(prs) > 0

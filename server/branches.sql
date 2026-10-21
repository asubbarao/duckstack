-- Dev works in the inframe checkout: duck_tails calls take '.' or no path at all.
SELECT content FROM read_text($cmd$mkdir -p ~/inframe && echo ok |$cmd$);
FROM cd(getenv('HOME') || '/inframe');
-- The branch views read the inframe git checkout (the working directory), which a machine without it (CI) lacks; they
-- are posted once dev is serving, so a missing checkout fails this post and nothing else.
-- branch_diff: what each local branch changed since it left origin/staging, and whether origin has it: the files a PR
-- shows, with no gh. branch_point = shared commits that no other shared commit has as a parent (git's
-- merge base). One row per branch and changed file; filter with WHERE branch_name = ….
-- branch_definition_changes: definitions each branch_diff file added, removed or modified: sitting_duck parses both
-- ends; a declaration wrapping a same-named definition (TS `const x` around its declarator) is dropped so each name
-- counts once, and the two ends join on qualified_name (scope path with per-name index), not on name. A file's blob
-- reads are correlated LATERALs, so WHERE branch_name = … reads only that branch; the side a file lacks gets a NULL uri,
-- because a WHERE inside the LATERAL does not stop the read.
-- git_changes and git_worktrees answer what agents ran git log/show/diff/status for (about 6,600 calls in the Claude
-- transcripts), for both repos. git_changes: every file each commit on any branch changed against each parent, read
-- live; a WHERE on commit_date diffs only those commits (2 days, both repos: 24 s, most of it walking the branches).
-- git_worktrees: every checkout of either repo with its branch and its uncommitted files (none: one row, NULL file).
WITH program AS (
    SELECT $views$
CREATE OR REPLACE VIEW git_changes AS
WITH repos AS (
  SELECT unnest([getenv('HOME') || '/inframe', getenv('HOME') || '/duckdb-skills']) AS repo
), commits AS (
  SELECT DISTINCT r.repo, l.commit_hash, l.author_name, l.commit_date, l.message
  FROM repos r
  CROSS JOIN LATERAL git_branches_each(r.repo) b
  CROSS JOIN LATERAL git_log_each(r.repo, b.commit_hash) l
)
SELECT c.*, p.parent_hash, d.file_path, d.file_ext, d.status, d.old_path
FROM commits c
CROSS JOIN LATERAL git_parents_each(c.repo, c.commit_hash) p
CROSS JOIN LATERAL git_diff_tree_each(c.repo, p.parent_hash, c.commit_hash) d;
CREATE OR REPLACE VIEW git_worktrees AS
WITH repos AS (
  SELECT unnest([getenv('HOME') || '/inframe', getenv('HOME') || '/duckdb-skills']) AS repo
), worktrees AS (
  SELECT r.repo, rtrim(substr(l.content, 10), E'\n') AS worktree
  FROM repos r CROSS JOIN LATERAL read_lines_lateral(tera_render($c$git -C '{{ repo }}' worktree list --porcelain |$c$, r::JSON, autoescape := false)) l
  WHERE starts_with(l.content, 'worktree ')
), branches AS (
  SELECT w.*, rtrim(b.content, E'\n') AS branch
  FROM worktrees w CROSS JOIN LATERAL read_lines_lateral(tera_render($c$git -C '{{ worktree }}' rev-parse --abbrev-ref HEAD |$c$, w::JSON, autoescape := false)) b
), changed AS (
  SELECT b.repo, b.worktree, b.branch, s.file_path, s.file_ext, s.status, s.staged, s.unstaged, s.old_path
  FROM branches b CROSS JOIN LATERAL git_status_each(b.worktree) s
)
SELECT * FROM changed
UNION ALL BY NAME
SELECT repo, worktree, branch FROM branches ANTI JOIN changed USING (worktree);
CREATE OR REPLACE VIEW branch_diff AS
WITH local_branches AS (
    SELECT * FROM git_branches() WHERE NOT is_remote
), remote_branches AS (
    SELECT branch_name AS remote_branch_name, commit_hash AS remote_commit_hash FROM git_branches() WHERE is_remote
), tracked_branches AS (
    SELECT local_branches.*, remote_branches.remote_branch_name, remote_branches.remote_commit_hash,
           remote_branches.remote_commit_hash IS NOT DISTINCT FROM local_branches.commit_hash AS is_pushed
    FROM local_branches
    LEFT JOIN remote_branches ON remote_branches.remote_branch_name = 'origin/' || local_branches.branch_name
), staging_commits AS (
    SELECT commit_hash FROM git_log('.', 'origin/staging')
), staging_parent_edges AS (
    SELECT commit_hash, parent_hash FROM git_parents('.', 'origin/staging')
), branch_history AS (
    SELECT tracked_branches.branch_name, history.commit_hash
    FROM tracked_branches CROSS JOIN LATERAL git_log_each(tracked_branches.repo_path, tracked_branches.commit_hash) history
), shared_history AS (
    SELECT * FROM branch_history SEMI JOIN staging_commits USING (commit_hash)
), shared_parents AS (
    SELECT shared_history.branch_name, staging_parent_edges.parent_hash AS commit_hash
    FROM shared_history JOIN staging_parent_edges USING (commit_hash)
), branch_points AS (
    SELECT branch_name, commit_hash AS branch_point FROM shared_history
    ANTI JOIN shared_parents USING (branch_name, commit_hash)
)
SELECT tracked_branches.*, branch_points.branch_point, changed_file.* EXCLUDE (repo_path),
       git_uri(tracked_branches.repo_path, changed_file.file_path, branch_points.branch_point) AS before_uri,
       git_uri(tracked_branches.repo_path, changed_file.file_path, tracked_branches.commit_hash) AS after_uri
FROM tracked_branches
JOIN branch_points USING (branch_name)
CROSS JOIN LATERAL git_diff_tree_each(tracked_branches.repo_path, branch_points.branch_point, tracked_branches.commit_hash) changed_file;
CREATE OR REPLACE VIEW branch_definition_changes AS
WITH file_sides AS (
    SELECT branch_diff.branch_name, branch_diff.file_path, 'before' AS side, file_read.text
    FROM branch_diff CROSS JOIN LATERAL git_read_each(branch_diff.before_uri) file_read
    WHERE branch_diff.status <> 'added'
    UNION ALL
    SELECT branch_diff.branch_name, branch_diff.file_path, 'after' AS side, file_read.text
    FROM branch_diff CROSS JOIN LATERAL git_read_each(branch_diff.after_uri) file_read
    WHERE branch_diff.status <> 'deleted'
), nodes AS (
    SELECT branch_name, file_path, side, unnest(parse_ast_list(text, detect_language(file_path)), recursive := true)
    FROM file_sides
    WHERE detect_language(file_path) IS NOT NULL
), definitions AS (
    SELECT * FROM nodes WHERE is_definition(semantic_type) AND name <> ''
), wrapper_definitions AS (
    SELECT parent.branch_name, parent.file_path, parent.side, parent.node_id
    FROM definitions parent JOIN definitions child
      ON child.branch_name = parent.branch_name AND child.file_path = parent.file_path AND child.side = parent.side
     AND child.parent_id = parent.node_id AND child.name = parent.name
), own_definitions AS (
    SELECT * FROM definitions ANTI JOIN wrapper_definitions USING (branch_name, file_path, side, node_id)
), before_definitions AS (
    SELECT * FROM own_definitions WHERE side = 'before'
), after_definitions AS (
    SELECT * FROM own_definitions WHERE side = 'after'
)
SELECT coalesce(after_definitions.branch_name, before_definitions.branch_name) AS branch_name,
       coalesce(after_definitions.file_path, before_definitions.file_path) AS file_path,
       coalesce(after_definitions.qualified_name, before_definitions.qualified_name) AS qualified_name,
       coalesce(after_definitions.name, before_definitions.name) AS name,
       coalesce(after_definitions.type, before_definitions.type) AS node_type,
       CASE WHEN before_definitions.node_id IS NULL THEN 'added'
            WHEN after_definitions.node_id IS NULL THEN 'removed'
            WHEN after_definitions.descendant_count <> before_definitions.descendant_count THEN 'modified'
            WHEN after_definitions.peek <> before_definitions.peek THEN 'modified'
            ELSE 'unchanged' END AS change,
       before_definitions.start_line AS before_start_line, before_definitions.end_line AS before_end_line,
       after_definitions.start_line AS after_start_line, after_definitions.end_line AS after_end_line,
       before_definitions.descendant_count AS before_descendant_count, after_definitions.descendant_count AS after_descendant_count,
       before_definitions.peek AS before_peek, after_definitions.peek AS after_peek
FROM before_definitions FULL JOIN after_definitions
  ON after_definitions.branch_name = before_definitions.branch_name
 AND after_definitions.file_path = before_definitions.file_path
 AND after_definitions.qualified_name = before_definitions.qualified_name
$views$ AS sql
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM program
)
SELECT receipt.status FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);
-- issue_work: where each InFrame issue's work stands, one row per inf-NNNN worktree: its Linear state (linctl, issues
-- updated in 6 weeks), commits behind and ahead of origin/staging, whether origin has its head, uncommitted files, PRs on its branch
-- and the agent sessions in it over 3 days with their last prompt. Status comes from here, not from commits or Linear
-- alone: written work often sits uncommitted. Binding it runs gh and linctl, so it is its own post: a machine without
-- them loses this view and nothing else.
WITH program AS (
    SELECT $view$
CREATE OR REPLACE VIEW issue_work AS
WITH issue_worktrees AS (
  SELECT DISTINCT regexp_extract(branch, 'inf-[0-9]+') AS issue, worktree, branch
  FROM git_worktrees
  WHERE repo = getenv('HOME') || '/inframe' AND regexp_extract(branch, 'inf-[0-9]+') <> ''
), uncommitted AS (
  SELECT worktree, list({status: status, file_path: file_path} ORDER BY file_path) AS uncommitted_files
  FROM git_worktrees WHERE file_path IS NOT NULL GROUP BY worktree
), pushed_branches AS (
  SELECT l.branch_name AS branch, r.commit_hash IS NOT DISTINCT FROM l.commit_hash AS pushed
  FROM git_branches() l LEFT JOIN git_branches() r ON r.is_remote AND r.branch_name = 'origin/' || l.branch_name
  WHERE NOT l.is_remote
), position_statements AS (
  SELECT worktree,
         tera_render($tpl$SELECT * FROM read_csv($c$git -C '{{ worktree }}' rev-list --left-right --count origin/staging...HEAD |$c$, header := false, delim := E'\t', names := ['behind_staging', 'ahead_of_staging'])$tpl$,
                     json_object('worktree', worktree), autoescape := false) AS executable_sql
  FROM issue_worktrees
), positions_posted AS (
  SELECT array_agg({worktree: worktree, receipt: selfdispatch(executable_sql)}) AS arr FROM position_statements
), positions AS (
  SELECT t.r.worktree AS worktree, (t.r.receipt.body ->> '$[0].behind_staging')::INT AS behind_staging,
         (t.r.receipt.body ->> '$[0].ahead_of_staging')::INT AS ahead_of_staging, t.r.receipt.error AS git_error
  FROM positions_posted CROSS JOIN UNNEST(arr) AS t(r)
), prs AS (
  SELECT number, title, state, headRefName
  FROM read_json($c$gh pr list -R inframe-risk/inframe --state all --limit 300 --json number,title,state,headRefName |$c$)
), issue_prs AS (
  SELECT w.worktree, list({number: p.number, state: p.state, title: p.title} ORDER BY p.number DESC) AS prs
  FROM issue_worktrees w JOIN prs p ON p.headRefName = w.branch GROUP BY w.worktree
), window_messages AS (
  SELECT session_id, timestamp, is_prompt, head, git_branch, cwd FROM agent.messages WHERE timestamp > now() - INTERVAL 3 DAY
), recent AS (
  SELECT w.worktree, m.session_id, m.timestamp, m.is_prompt, m.head FROM window_messages m JOIN issue_worktrees w ON m.git_branch = w.branch
  UNION
  SELECT w.worktree, m.session_id, m.timestamp, m.is_prompt, m.head FROM window_messages m JOIN issue_worktrees w ON m.cwd = w.worktree
), session_activity AS (
  SELECT worktree, session_id, max(timestamp) AS last_seen,
         arg_max(CASE WHEN is_prompt THEN left(head, 120) END, CASE WHEN is_prompt THEN timestamp END) AS last_prompt
  FROM recent GROUP BY ALL
), sessions AS (
  SELECT worktree, max(last_seen) AS last_seen,
         list({session_id: session_id, last_seen: last_seen, last_prompt: last_prompt} ORDER BY last_seen DESC) AS sessions
  FROM session_activity GROUP BY worktree
), linear_issues AS (
  SELECT lower(identifier) AS issue, state.name AS linear_state, title AS linear_title
  FROM read_json($c$linctl issue list --team INF --include-completed --newer-than 6_weeks_ago --limit 250 --json |$c$)
)
SELECT w.issue, l.linear_state, l.linear_title, w.worktree, w.branch, p.behind_staging, p.ahead_of_staging, b.pushed,
       len(c.uncommitted_files) AS uncommitted, s.last_seen, r.prs, c.uncommitted_files, s.sessions, p.git_error
FROM issue_worktrees w
LEFT JOIN pushed_branches b USING (branch)
LEFT JOIN positions p USING (worktree)
LEFT JOIN uncommitted c USING (worktree)
LEFT JOIN issue_prs r USING (worktree)
LEFT JOIN sessions s USING (worktree)
LEFT JOIN linear_issues l USING (issue)
$view$ AS sql
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM program
)
SELECT receipt.status FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

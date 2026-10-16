-- Dev works in the inframe checkout: duck_tails calls take '.' or no path at all.
SELECT content FROM read_text('mkdir -p ' || getenv('HOME') || '/inframe && echo ok |') LIMIT 1;
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
SELECT selfdispatch($views$
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
  FROM repos r CROSS JOIN LATERAL read_lines_lateral('git -C ' || r.repo || ' worktree list --porcelain |') l
  WHERE starts_with(l.content, 'worktree ')
), branches AS (
  SELECT w.*, rtrim(b.content, E'\n') AS branch
  FROM worktrees w CROSS JOIN LATERAL read_lines_lateral('git -C ' || w.worktree || ' rev-parse --abbrev-ref HEAD |') b
)
SELECT b.repo, b.worktree, b.branch, s.file_path, s.file_ext, s.status, s.staged, s.unstaged, s.old_path
FROM branches b LEFT JOIN LATERAL (SELECT * FROM git_status_each(b.worktree)) s ON true;
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
    FROM tracked_branches, LATERAL git_log_each(tracked_branches.repo_path, tracked_branches.commit_hash) history
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
    FROM branch_diff, LATERAL git_read_each(branch_diff.before_uri) file_read
    WHERE branch_diff.status <> 'added'
    UNION ALL
    SELECT branch_diff.branch_name, branch_diff.file_path, 'after' AS side, file_read.text
    FROM branch_diff, LATERAL git_read_each(branch_diff.after_uri) file_read
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
$views$).status;

-- Dev works in the inframe checkout: duck_tails calls take '.' or no path at all.
SELECT content FROM read_text($cmd$mkdir -p ~/inframe && echo ok |$cmd$);
FROM cd(getenv('HOME') || '/inframe');
-- The branch views read the inframe git checkout (the working directory), which a machine without it (CI) lacks; they
-- are posted once dev is serving, so a missing checkout fails this post and nothing else.
-- branch_diff: what each local branch changed since it left origin/staging, and whether origin has it: the files a PR
-- shows, with no gh. Git itself (for-each-ref, merge-base, diff --name-status) streams through shellfs: a WHERE on
-- branch_name reaches for-each-ref, so only that branch runs git (0.08 s for one branch; the duck_tails history walk
-- this replaced took 5.4 s and 6 M intermediate rows). One row per branch and changed file.
-- branch_definition_changes: definitions each branch_diff file added, removed or modified: sitting_duck parses both
-- ends; a declaration wrapping a same-named definition (TS `const x` around its declarator) is dropped so each name
-- counts once, and the two ends join on qualified_name (scope path with per-name index), not on name. A file's blob
-- reads are correlated LATERALs, so WHERE branch_name = … reads only that branch; the side a file lacks gets a NULL uri,
-- because a WHERE inside the LATERAL does not stop the read.
-- git_changes and git_worktrees answer what agents ran git log/show/diff/status for (about 6,600 calls in the Claude
-- transcripts), for both repos. git_changes: every file each commit on any branch changed against each parent, read
-- live; a WHERE on commit_date diffs only those commits (2 days, both repos: 24 s, most of it walking the branches).
-- git_worktrees: every checkout of either repo with its branch and its uncommitted files (none: one row, NULL file),
-- from git status --porcelain --branch per worktree; a WHERE on worktree runs git status in that one checkout only
-- (0.13 s; git_status_each over all of them took 2.7 s).
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
), status_lines AS (
  SELECT w.repo, w.worktree, rtrim(s.content, E'\n') AS line
  FROM worktrees w CROSS JOIN LATERAL read_lines_lateral(tera_render($c$git -C '{{ worktree }}' status --porcelain --branch |$c$, w::JSON, autoescape := false)) s
), branches AS (
  SELECT repo, worktree, string_split(string_split(substr(line, 4), '...')[1], ' ')[1] AS branch
  FROM status_lines WHERE starts_with(line, '## ')
), changed AS (
  SELECT repo, worktree, substr(line, 1, 2) AS xy, string_split(substr(line, 4), ' -> ') AS paths
  FROM status_lines WHERE NOT starts_with(line, '## ')
)
SELECT branches.*, changed.paths[-1] AS file_path,
       CASE WHEN len(changed.paths) > 1 THEN changed.paths[1] END AS old_path,
       CASE WHEN changed.xy = '??' THEN 'untracked' WHEN contains(changed.xy, 'U') THEN 'conflicted'
            WHEN contains(changed.xy, 'R') THEN 'renamed' WHEN contains(changed.xy, 'A') THEN 'added'
            WHEN contains(changed.xy, 'D') THEN 'deleted' WHEN changed.xy IS NOT NULL THEN 'modified' END AS status,
       changed.xy[1] NOT IN (' ', '?') AS staged, changed.xy[2] <> ' ' AS unstaged
FROM branches LEFT JOIN changed USING (repo, worktree);
CREATE OR REPLACE VIEW branch_diff AS
WITH refs AS (
    SELECT getenv('HOME') || '/inframe' AS repo_path, ref.*
    FROM read_csv($c$git -C ~/inframe for-each-ref refs/heads refs/remotes/origin --format='%(refname:short)%09%(objectname)' |$c$,
                  delim = E'\t', header = false, columns = {'ref_name': 'VARCHAR', 'commit_hash': 'VARCHAR'}) ref
), tracked_branches AS (
    SELECT local_ref.repo_path, local_ref.ref_name AS branch_name, local_ref.commit_hash,
           remote_ref.ref_name AS remote_branch_name, remote_ref.commit_hash AS remote_commit_hash,
           remote_ref.commit_hash IS NOT DISTINCT FROM local_ref.commit_hash AS is_pushed
    FROM refs local_ref
    LEFT JOIN refs remote_ref ON remote_ref.ref_name = 'origin/' || local_ref.ref_name
    WHERE NOT starts_with(local_ref.ref_name, 'origin/')
), branch_points AS (
    SELECT tracked_branches.*, rtrim(merge_base.content, E'\n') AS branch_point
    FROM tracked_branches CROSS JOIN LATERAL read_lines_lateral(tera_render($c$git -C '{{ repo_path }}' merge-base origin/staging {{ commit_hash }} |$c$, tracked_branches::JSON, autoescape := false)) merge_base
), changed_files AS (
    SELECT branch_points.*, string_split(rtrim(name_status.content, E'\n'), E'\t') AS fields
    FROM branch_points CROSS JOIN LATERAL read_lines_lateral(tera_render($c$git -C '{{ repo_path }}' diff --name-status {{ branch_point }} {{ commit_hash }} |$c$, branch_points::JSON, autoescape := false)) name_status
)
SELECT changed_files.* EXCLUDE (fields), fields[-1] AS file_path,
       CASE WHEN len(fields) > 2 THEN fields[2] END AS old_path,
       CASE fields[1][1] WHEN 'A' THEN 'added' WHEN 'D' THEN 'deleted' WHEN 'R' THEN 'renamed' WHEN 'C' THEN 'copied' ELSE 'modified' END AS status,
       git_uri(repo_path, coalesce(CASE WHEN len(fields) > 2 THEN fields[2] END, fields[-1]), branch_point) AS before_uri,
       git_uri(repo_path, fields[-1], commit_hash) AS after_uri
FROM changed_files;
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

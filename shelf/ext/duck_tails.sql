-- @ext: duck_tails
-- @rev: 742af7b (community, DuckDB 1.5.5 osx_arm64); docs at 1223e5d describe a newer build
-- @verified: 2026-09-17 — every statement below ran against ~/inframe (origin/staging vs origin/main)
-- @functions: git_log, git_tree, git_read, git_diff_tree, git_status, git_blame, git_blame_hunks, read_git_diff, git_uri, *_each
-- @needs: cd ~/inframe (or pass the repo path); `git fetch origin pull/N/head:prN` makes a PR a ref
-- @tags: git, history, blame, diff, pull request, review, rebase, what changed, who touched
-- @summary: Git history as tables. The three that matter: git_diff_tree for "which files", read_text
--   over git:// URIs + EXCEPT ALL for "which lines", git_blame for "whose lines". The built-in diff
--   functions are stubs in this build — do not use them.
LOAD duck_tails;

-- git_log([repo | 'git://repo@ref']) -> repo_path, commit_hash, author_name, author_email, committer_name,
--   committer_email, author_date, commit_date, message, parent_count, tree_hash  (newest first; walks all — LIMIT)
SELECT commit_hash[1:8] AS sha, author_name, strftime(author_date, '%Y-%m-%d') AS d, left(message, 80) AS msg
FROM git_log('.') LIMIT 10;

-- git_tree(repo, ref) | git_tree('git://repo@ref') -> git_uri, repo_path, commit_hash, tree_hash, file_path, file_ext ('.py'),
--   ref, blob_hash, commit_date, mode, size_bytes, kind ('file'|'tree'), is_text, encoding
--   The docs' one-arg git_tree('HEAD') returns 0 rows in 742af7b (the arg is taken as a path); kind is 'tree', not 'directory'.
SELECT file_ext, count(*) AS files, sum(size_bytes) AS bytes FROM git_tree('.', 'origin/main') WHERE kind = 'file' GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
--   → .py 2309 files / 26 MB, .tsx 1320, .ts 509, .md 162, .json 144, .tf 120

-- git_diff_tree(repo_or_dir [, from_ref [, to_ref]], path := '', untracked := false)  -- UNDOCUMENTED
--   -> repo_path, file_path, file_ext, status ('added'|'deleted'|'modified'|'renamed'|'copied'|'typechange'), old_path
--   FIRST ARG IS A PATH, NEVER A REF. One ref = that ref vs the working tree (the trap).
SELECT status, count(*) AS files, array_agg(file_path ORDER BY file_path)[1:5] AS sample
FROM git_diff_tree('.', 'origin/main', 'origin/staging') GROUP BY 1;                -- what staging carries that prod does not
FROM git_diff_tree('.', 'origin/main', 'origin/staging', path := 'platform/backend/app/alembic/versions/');  -- the migrations in that delta (0 rows on 09-17: none pending)

-- git_status([repo], untracked := false, ignored := false, path := '')  -- UNDOCUMENTED
--   -> repo_path, file_path, file_ext, status, status_flags, staged, unstaged, old_path
FROM git_status('.');

-- Lines added / removed between two revisions of one file: land both as line tables, EXCEPT ALL them.
-- (text_diff is a positional walk — an 8-line insert reports ~800 changes; text_diff_lines()/text_diff_stats() are stubs.)
WITH b AS (SELECT unnest(string_split(content, chr(10))) AS l FROM read_text('git://platform/backend/app/alembic/versions/0372.py@995d8ed58~1')),
     p AS (SELECT unnest(string_split(content, chr(10))) AS l FROM read_text('git://platform/backend/app/alembic/versions/0372.py@a1f56cae5'))
SELECT (SELECT array_agg(l) FROM (SELECT l FROM p EXCEPT ALL SELECT l FROM b)) AS added,
       (SELECT array_agg(l) FROM (SELECT l FROM b EXCEPT ALL SELECT l FROM p)) AS removed;

-- git_blame(file_or_uri, revision := 'HEAD', repo_path := '.', min_line, max_line, ignore_whitespace, use_mailmap, first_parent)
--   -> repo_path, file_path, file_ext, revision, line_number, line_content, commit_hash, author_name, author_email,
--      author_date, orig_commit_hash, orig_path, orig_line_number, boundary    (min/max_line make it cheap)
SELECT commit_hash[1:8] AS sha, author_name, strftime(author_date, '%Y-%m-%d') AS d, array_agg(line_number) AS lines
FROM git_blame('platform/backend/app/alembic/env.py', revision := 'origin/staging', min_line := 100, max_line := 135) GROUP BY ALL ORDER BY min(line_number);
--   → who put pg_advisory_xact_lock in env.py, and when

-- History of one path: LEFT JOIN LATERAL keeps commits where the file does not exist yet.
SELECT l.commit_hash[1:8] AS sha, l.author_date, r.size_bytes
FROM git_log() l LEFT JOIN LATERAL git_read_each(git_uri('.', 'platform/backend/scripts/prestart.sh', l.commit_hash)) r ON true LIMIT 20;

-- Data files in the repo, read at a revision by any reader — no checkout of that revision needed.
SELECT count(*) AS lines FROM read_csv('git://platform/backend/uv.lock@origin/main', header := false, delim := chr(7), columns := {line: 'VARCHAR'});

-- Gotchas: named parameters do not bind inside LATERAL on 1.5.5 (positional forms only there);
-- git_read has no (path, ref) form — build the URI with git_uri(repo, file, ref).

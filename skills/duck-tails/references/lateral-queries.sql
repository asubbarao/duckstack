-- Duck Tails native LATERAL recipes, adapted from the user's supplied guide:
-- https://duck-tails.readthedocs.io/en/latest/guide/lateral-joins/
-- Run one SELECT at a time on dev; replace the absolute repo/path selectors.
-- LOAD duck_tails first. No tables, shell loops, or per-file HTTP dispatch.
-- Verified 2026-09-29: two selected files read; history/tree calls returned
-- the sole available commit of this local bare clone. Not a multi-commit proof.

-- 1. Selected files -> bytes/text. Prune the tree before reading bodies.
WITH selected_files AS (
    SELECT file_path, git_uri
    FROM git_tree('/Users/aloksubbarao/reviews/closure.git', 'HEAD')
    WHERE kind = 'file'
      AND file_path IN ('samples/gen/corpus.sql', 'samples/gen/court.sql')
)
SELECT sf.file_path, gr.size_bytes, gr.is_text, gr.text
FROM selected_files sf
JOIN LATERAL git_read_each(sf.git_uri) gr ON true;

-- 2. One file across bounded history; LEFT keeps the commit if no row is returned.
-- Do not assume every error becomes a skipped row; inspect actual errors.
WITH recent_commits AS (
    SELECT commit_hash, author_date
    FROM git_log(repo_path := '/Users/aloksubbarao/reviews/closure.git')
    ORDER BY author_date DESC, commit_hash
    LIMIT 3
)
SELECT rc.*, gr.blob_hash, gr.size_bytes
FROM recent_commits rc
LEFT JOIN LATERAL git_read_each(
    git_uri('/Users/aloksubbarao/reviews/closure.git',
            'samples/gen/corpus.sql', rc.commit_hash)
) gr ON true
ORDER BY rc.author_date DESC;

-- 3. A tree at each selected commit. These are snapshot contents, NOT changed files.
WITH recent_commits AS (
    SELECT commit_hash
    FROM git_log(repo_path := '/Users/aloksubbarao/reviews/closure.git')
    ORDER BY author_date DESC, commit_hash
    LIMIT 2
)
SELECT rc.commit_hash, gt.file_path, gt.blob_hash
FROM recent_commits rc
JOIN LATERAL git_tree_each(
    '/Users/aloksubbarao/reviews/closure.git', rc.commit_hash
) gt ON true
WHERE gt.file_path = 'samples/gen/corpus.sql';

-- 4. Discover installed overloads before adapting branch/tag/parent recipes.
SELECT function_name, parameters, parameter_types
FROM duckdb_functions()
WHERE function_name IN (
    'git_log_each', 'git_tree_each', 'git_read_each',
    'git_branches_each', 'git_tags_each', 'git_parents_each'
)
ORDER BY function_name, len(parameters);

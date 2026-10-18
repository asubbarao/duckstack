-- Duck Tails native LATERAL recipes, adapted from the user's supplied guide:
-- https://duck-tails.readthedocs.io/en/latest/guide/lateral-joins/
-- Run one SELECT at a time on dev; replace <repo> and the path selectors.
-- LOAD duck_tails first. No tables, shell loops, or per-file HTTP dispatch.
-- Verified 2026-10-17 on ~/duckdb-skills: 1 read two files; 2 read SQL-MANIFESTO.md at the
-- 3 newest commits (and returned no rows, not an error, at commits before it existed); 3 and 4 ran.

-- 1. Selected files -> bytes/text. Prune the tree before reading bodies.
WITH selected_files AS (
    SELECT file_path, git_uri
    FROM git_tree('<repo>', 'HEAD')
    WHERE kind = 'file'
      AND file_path IN ('samples/gen/corpus.sql', 'samples/gen/court.sql')
)
SELECT sf.file_path, gr.size_bytes, gr.is_text, gr.text
FROM selected_files AS sf
CROSS JOIN LATERAL git_read_each(sf.git_uri) AS gr;

-- 2. One file across bounded history. git_read_each raises "file not found" at a commit
-- without the file (a LEFT JOIN does not help), so find it in each commit's tree first.
WITH recent_commits AS (
    SELECT commit_hash, author_date
    FROM git_log(repo_path := '<repo>')
    ORDER BY author_date DESC, commit_hash
    LIMIT 3
), present AS (
    SELECT rc.commit_hash, rc.author_date, gt.git_uri
    FROM recent_commits AS rc
    CROSS JOIN LATERAL git_tree_each('<repo>', rc.commit_hash) AS gt
    WHERE gt.file_path = 'samples/gen/corpus.sql'
)
SELECT p.commit_hash, p.author_date, gr.blob_hash, gr.size_bytes
FROM present AS p
CROSS JOIN LATERAL git_read_each(p.git_uri) AS gr
ORDER BY p.author_date DESC;

-- 3. A tree at each selected commit. These are snapshot contents, NOT changed files.
WITH recent_commits AS (
    SELECT commit_hash
    FROM git_log(repo_path := '<repo>')
    ORDER BY author_date DESC, commit_hash
    LIMIT 2
)
SELECT rc.commit_hash, gt.file_path, gt.blob_hash
FROM recent_commits AS rc
CROSS JOIN LATERAL git_tree_each('<repo>', rc.commit_hash) AS gt
WHERE gt.file_path = 'samples/gen/corpus.sql';

-- 4. Discover installed overloads before adapting branch/tag/parent recipes.
SELECT function_name, parameters, parameter_types
FROM duckdb_functions()
WHERE function_name IN (
    'git_log_each', 'git_tree_each', 'git_read_each',
    'git_branches_each', 'git_tags_each', 'git_parents_each'
)
ORDER BY function_name, len(parameters);

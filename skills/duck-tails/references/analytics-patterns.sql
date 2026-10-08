-- Adapted from https://duck-tails.readthedocs.io/en/latest/ (analytics/history/advanced).
-- Run one query at a time. '.' means the DuckDB process's repository, not the caller's.
-- Replace it with an absolute repository path when using a server elsewhere.
-- Verified 2026-09-29 on dev using ~/duckdb-skills: grouped tree totals and four
-- bounded historical SKILL.md reads, selected-file metadata and distinct-content grouping.
-- Other recipes compose those same native forms; dataset paths are caller examples.
INSTALL duck_tails FROM community;
LOAD duck_tails;

-- 1. Reuse a common source CTE for detail and totals.
-- One definition is easier to revise; it is not proof of one physical scan.
-- DuckDB chooses CTE inlining/materialization. Use EXPLAIN when execution cost matters.
WITH tree AS (
    SELECT * FROM git_tree('.', 'HEAD') WHERE kind = 'file'
)
SELECT file_ext, coalesce(len(array_agg(file_path)), 0) AS file_count,
       sum(size_bytes) AS total_bytes
FROM tree
GROUP BY file_ext
UNION ALL
SELECT 'TOTAL', coalesce(len(array_agg(file_path)), 0), sum(size_bytes)
FROM tree;

-- 2. Limit BEFORE reading bodies across history, not only after LATERAL.
-- Date ordering is activity ordering, not a guaranteed ancestry order.
WITH recent_commits AS (
    SELECT commit_hash, author_date
    FROM git_log(repo_path := '.')
    ORDER BY author_date DESC, commit_hash
    LIMIT 4
)
SELECT l.commit_hash, l.author_date, r.file_path, r.blob_hash, r.size_bytes
FROM recent_commits l
JOIN LATERAL git_read_each(git_uri('.', 'README.md', l.commit_hash)) r ON true;

-- 3. Prune file paths/types BEFORE reading text. Keep metadata and the raw body.
WITH selected_files AS (
    SELECT * FROM git_tree('.', 'HEAD')
    WHERE kind = 'file' AND file_path IN ('README.md', 'package.json')
)
SELECT t.file_path, t.git_uri, t.blob_hash, r.text, r.encoding, r.truncated
FROM selected_files t
JOIN LATERAL git_read_each(t.git_uri) r ON true;

-- 4. Same committed dataset at literal revisions, no checkout or captured repo variable.
-- Replace data/sales.csv with a real tracked dataset. Native readers retain their options.
SELECT 'HEAD' AS revision, * FROM read_csv('git://data/sales.csv@HEAD')
UNION ALL BY NAME
SELECT 'HEAD~1' AS revision, * FROM read_csv('git://data/sales.csv@HEAD~1');

-- 5. Changes in one file's CONTENT, not merely commits whose snapshot contains it.
-- Distinct blobs identify distinct contents; this does not name the introducing commit.
WITH recent_commits AS (
    SELECT commit_hash, author_date FROM git_log(repo_path := '.')
    ORDER BY author_date DESC, commit_hash LIMIT 7
), snapshots AS (
    SELECT l.commit_hash, l.author_date, r.blob_hash, r.size_bytes
    FROM recent_commits l
    JOIN LATERAL git_read_each(git_uri('.', 'README.md', l.commit_hash)) r ON true
)
SELECT blob_hash, size_bytes,
       array_agg(commit_hash ORDER BY author_date DESC, commit_hash) AS snapshot_commits
FROM snapshots GROUP BY ALL;

-- 6. Native per-commit trees: snapshot contents, NOT files changed by that commit.
WITH recent_commits AS (
    SELECT commit_hash FROM git_log(repo_path := '.')
    ORDER BY author_date DESC, commit_hash LIMIT 4
)
SELECT l.commit_hash, t.file_path, t.blob_hash, t.size_bytes
FROM recent_commits l
JOIN LATERAL git_tree_each('.', l.commit_hash) t ON true
WHERE t.kind = 'file' AND t.file_path = 'README.md';

-- 7. Contributor activity: retain the commit identities behind the count.
-- Names can alias one person; use author_email or an explicit identity mapping if needed.
SELECT author_name,
       array_agg(commit_hash ORDER BY author_date DESC, commit_hash) AS commits,
       len(commits) AS commit_count
FROM git_log(repo_path := '.')
WHERE author_date > current_date - INTERVAL '30 days'
GROUP BY author_name ORDER BY commit_count DESC LIMIT 7;

-- Caveats when adapting the upstream examples:
-- * Installed git_tree uses (repo_path, ref); git_tree('HEAD') may mean repo='HEAD'.
-- * A SELECT ... LIMIT 0 describes no metadata rows. Use DESCRIBE SELECT ... for schema.
-- * read_csv/read_json/read_parquet cannot generally consume a URI column in LATERAL.
--   Use fixed literal refs/globs or self-dispatch complete literal-argument queries per row.
-- * Snapshot existence is not file authorship, bus factor, or changed-file count.
--   Use blame or parent-aware git diffs for those questions.
-- * Missing/deleted files, binary text=NULL and empty results need explicit interpretation.

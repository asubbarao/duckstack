-- =============================================================================
-- declarative_ls.sql — progressive discovery: one lsr from the root, prune by name, type by
-- scalar. Runs as a query; materialize only after it is right.
--
-- Verified DuckDB 1.5.5 osx_arm64, hostfs 2026-09-17. The previous version wrote
-- `FROM roots r, lsr(r.path, 1)` — lsr is a table function and binds a literal, so that is a
-- binder error ("does not support lateral join column parameters"). Depth is the knob:
-- lsr(root, depth) walks every subdirectory in one call; the per-root fan-out that needed a
-- column is declarative_pipeline.sql's job (self-dispatch), not this file's.
-- =============================================================================
LOAD hostfs;

WITH
-- lsr(path, depth) -> path ; depth 2 = the root's children and grandchildren
found AS (SELECT path FROM lsr('/Users/aloksubbarao/personal/self-dispatch', 2)),
-- prune by NAME before typing: a skipped dir never reaches a scalar
kept  AS (SELECT path FROM found
          WHERE NOT list_has_any(parse_path(path),
                ['node_modules', '.git', '__pycache__', '.venv', 'venv', '.tox',
                 'dist', 'build', '.mypy_cache', '.pytest_cache', 'dump']))
-- the scalars ARE the type: names = function names, every column kept
SELECT path,
       is_dir(path)             AS is_dir,
       is_file(path)            AS is_file,
       file_name(path)          AS file_name,
       file_extension(path)     AS file_extension,
       file_size(path)          AS file_size,
       hsize(file_size(path))   AS hsize,
       file_last_modified(path) AS file_last_modified
FROM kept
WHERE is_file(path) AND file_size(path) > 0
ORDER BY path;

-- VALIDATION (as comments; run by hand)
--   SELECT count(*) FILTER (WHERE is_dir) AS dirs, count(*) FILTER (WHERE is_file) AS files FROM (<the SELECT above without its WHERE>);
--   0 rows = wrong root or depth, not "no files"

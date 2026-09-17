-- =============================================================================
-- declarative_discover.sql
-- Lazy progressive lsr → prune dirs → typed ext filter → hostfs scalars
-- (names = function names). Run as a query first; materialize only after.
-- =============================================================================

LOAD hostfs;

-- Progressive discovery (~9k on personal depth 3 in prior run)
WITH wave0 AS (
  SELECT path
  FROM lsr('/Users/aloksubbarao/personal', 3)
),
wave1 AS (
  SELECT path
  FROM wave0
  WHERE NOT list_has_any(
    parse_path(path),
    ['node_modules', '.git', 'dump', '__pycache__', '.venv', 'venv', '.tox',
     'dist', 'build', '.mypy_cache', '.pytest_cache']
  )
),
wave2 AS (
  SELECT
    path,
    absolute_path(path) AS absolute_path,
    file_name(path) AS file_name,
    file_extension(path) AS file_extension,
    path_type(path) AS path_type,
    is_dir(path) AS is_dir,
    is_file(path) AS is_file,
    path_exists(path) AS path_exists,
    file_size(path) AS file_size,
    hsize(file_size(path)) AS hsize,
    file_last_modified(path) AS file_last_modified
  FROM wave1
  WHERE is_file(path)
    AND file_extension(path) IN (
      '.py', '.sh', '.txt', '.md', '.sql',
      '.csv', '.json', '.jsonl', '.yaml', '.yml', '.html', '.htm'
    )
    AND file_size(path) > 0
    AND file_size(path) < 500000
)
SELECT
  count(*) AS n_files,
  sum(file_size) AS sum_bytes,
  hsize(sum(file_size)::BIGINT) AS sum_hsize
FROM wave2;

-- Per-directory size sums
WITH wave0 AS (
  SELECT path FROM lsr('/Users/aloksubbarao/personal', 3)
),
wave1 AS (
  SELECT path FROM wave0
  WHERE NOT list_has_any(
    parse_path(path),
    ['node_modules', '.git', 'dump', '__pycache__', '.venv', 'venv', '.tox',
     'dist', 'build', '.mypy_cache', '.pytest_cache']
  )
),
wave2 AS (
  SELECT path, file_size(path) AS file_size
  FROM wave1
  WHERE is_file(path)
    AND file_extension(path) IN (
      '.py', '.sh', '.txt', '.md', '.sql',
      '.csv', '.json', '.jsonl', '.yaml', '.yml', '.html', '.htm'
    )
    AND file_size(path) > 0 AND file_size(path) < 500000
)
SELECT
  array_to_string(list_slice(parse_path(path), 1, 5), '/') AS dir5,
  count(*) AS n_files,
  sum(file_size) AS sum_bytes,
  hsize(sum(file_size)::BIGINT) AS sum_hsize
FROM wave2
GROUP BY 1
ORDER BY sum_bytes DESC
LIMIT 10;

-- Materialize (only after the query above works), example:
-- duckdb personal/self-dispatch/data/personal_files.duckdb
-- CREATE OR REPLACE TABLE personal_files_typed AS <wave2 SELECT *>;

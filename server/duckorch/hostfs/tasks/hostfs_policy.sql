-- @task name=hostfs_policy
-- @description Folder names the crawl never descends into, and the file size read in full.
-- @outputs hostfs.policy
-- A name here is pruned before its folder is listed, so its subtree costs nothing.
CREATE SCHEMA IF NOT EXISTS hostfs;
CREATE OR REPLACE TABLE hostfs.policy AS
SELECT 'skip_dir' AS kind, name FROM (
  SELECT 'node_modules' AS name UNION ALL SELECT '__pycache__' UNION ALL SELECT 'venv'
  UNION ALL SELECT 'dist' UNION ALL SELECT 'build' UNION ALL SELECT 'dump'
  UNION ALL SELECT 'target' UNION ALL SELECT 'coverage')
UNION ALL SELECT 'max_content_bytes', '1048576';

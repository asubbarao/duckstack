-- @ext: ducklake
-- @rev: d8a1881e (core, DuckDB 1.5.5); installed and loaded on dev
-- @verified: 2026-09-17 — local catalog + local data path: create, insert, snapshots(), AT (VERSION => n) all ran
-- @functions: ATTACH 'ducklake:…', snapshots(), AT (VERSION|TIMESTAMP), ducklake_expire_snapshots, DATA_INLINING_ROW_LIMIT
-- @needs: nothing for a local lake; an S3 secret only when DATA_PATH is s3://
-- @tags: lakehouse, landing, history, snapshot, time travel, parquet, raw tables, backfill, etl target
-- @summary: The landing catalog for the raw pulls. A DuckLake is a metadata DuckDB + parquet under DATA_PATH;
--   every INSERT is a snapshot, so a re-pull never loses the previous version and a backfill is auditable.
LOAD ducklake;

-- Local lake: no S3, no secrets. Metadata file + data directory. (This is what dev can do today.)
ATTACH 'ducklake:/Users/aloksubbarao/.duck/lake/meta.ducklake' AS lake (DATA_PATH '/Users/aloksubbarao/.duck/lake/data/');

-- Raw tables, one per source, the API response kept whole plus the pull window.
CREATE TABLE IF NOT EXISTS lake.raw_github_workflow_runs AS
  SELECT now() AS pulled_at, TIMESTAMP '1970-01-01' AS win_start, TIMESTAMP '1970-01-01' AS win_end, * FROM gh_runs LIMIT 0;
INSERT INTO lake.raw_github_workflow_runs SELECT now(), getvariable('win_start'), getvariable('win_end'), * FROM gh_runs;

-- Every write is a snapshot; a re-run of the same window is a new snapshot, not an overwrite.
SELECT snapshot_id, snapshot_time, changes FROM lake.snapshots() ORDER BY snapshot_id DESC LIMIT 5;
SELECT count(*) FROM lake.raw_github_workflow_runs AT (VERSION => 1);
SELECT count(*) FROM lake.raw_github_workflow_runs AT (TIMESTAMP => now() - INTERVAL 1 HOUR);

-- Dedupe is a view over the lake, never a DELETE in the raw layer:
CREATE OR REPLACE VIEW lake.github_workflow_runs AS
  SELECT * EXCLUDE (rn) FROM (SELECT *, row_number() OVER (PARTITION BY id ORDER BY pulled_at DESC) AS rn FROM lake.raw_github_workflow_runs) WHERE rn = 1;

-- Small inserts stay inline in the metadata DB until DATA_INLINING_ROW_LIMIT; set it to 0 when the data must be parquet
-- (S3 lakes; this is the CONTEXT.md note "small inserts never reach S3").
--   ATTACH 'ducklake:…' AS lake (DATA_PATH 's3://bucket/prefix/', DATA_INLINING_ROW_LIMIT 0);

-- Housekeeping: CALL lake.ducklake_expire_snapshots(older_than => now() - INTERVAL 90 DAY);

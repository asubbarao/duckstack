-- Keeps stream.blocks (blocks.sql fills it at boot) current: now and every 15 minutes, 30 s after the copies. The rows of
-- every Parquet file written in the last 30 minutes (twice the cron period) are replaced; the filter on the file's own
-- modified time runs per file inside the Parquet scan, so unchanged files are not read (~3 s: the is_repeat window over
-- the whole table is 2 s of it). Then the BM25 index is rebuilt from that step's receipt.
WITH program AS (
    SELECT $refresh$
WITH window_step AS (
    SELECT array_agg(selfdispatch($w$
CREATE OR REPLACE TABLE stream.main.blocks AS
WITH fresh AS (
    SELECT *, false AS is_repeat FROM stream.main.parsed
    WHERE file_last_modified(stored) >= now()::TIMESTAMP - INTERVAL 30 MINUTE
), kept_and_fresh AS (
    SELECT * FROM stream.main.blocks ANTI JOIN fresh USING (stored)
    UNION ALL BY NAME
    SELECT * FROM fresh
)
SELECT * EXCLUDE (is_repeat),
       uuid IS NOT NULL AND (file_path, line) IS DISTINCT FROM arg_min((file_path, line), (timestamp, file_path, line)) OVER (PARTITION BY uuid) AS is_repeat
FROM kept_and_fresh
$w$)) AS receipts
), index_step AS (
    SELECT array_agg(selfdispatch($p$PRAGMA create_fts_index('stream.main.blocks', 'block_key', 'message_content', overwrite = 1)$p$)) AS receipts
    FROM window_step CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200
)
SELECT r.* FROM window_step CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL SELECT r.* FROM index_step CROSS JOIN UNNEST(receipts) AS t(r);
$refresh$ AS sql
), posted AS (
    SELECT sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY sql
)
SELECT cron(sql, '30 */15 * * * *') AS job, r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

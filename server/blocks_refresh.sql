-- Fills and keeps stream.blocks (blocks.sql) current: now and every 15 minutes, 30 s after the copies, it replaces the rows
-- of each transcript agent.entries shows changed in the last 30 minutes or not in the table yet (at boot, all of them; a
-- literal list, so the scan reads only those files), recomputes is_repeat over the whole table, then rebuilds the BM25
-- index from that step's receipt. Nothing changed, no post.
WITH program AS (
    SELECT $refresh$
WITH transcript AS (
    SELECT path, modified FROM dev.agent.entries WHERE reader = 'read_json'
), stale AS (
    SELECT path FROM transcript WHERE modified >= now()::TIMESTAMP - INTERVAL 30 MINUTE   -- twice the cron period
    UNION
    SELECT path FROM transcript ANTI JOIN stream.main.blocks b ON b.file_path = transcript.path
), changed AS (
    SELECT string_agg(quote_literal(path), ', ') AS files FROM stale
), rendered AS (
    SELECT tera_render($w$
CREATE OR REPLACE TABLE stream.main.blocks AS
SELECT * EXCLUDE (is_repeat),
       uuid IS NOT NULL AND (file_path, line) IS DISTINCT FROM arg_min((file_path, line), (timestamp, file_path, line)) OVER (PARTITION BY uuid) AS is_repeat
FROM (SELECT * FROM stream.main.blocks WHERE file_path NOT IN ({{ files }})
      UNION ALL BY NAME
      SELECT * FROM stream.main.parsed WHERE file_path IN ({{ files }}))
$w$, changed::JSON, autoescape := false) AS sql
    FROM changed WHERE files IS NOT NULL
), window_step AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
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

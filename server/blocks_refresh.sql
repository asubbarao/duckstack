-- Fills and keeps stream.blocks (blocks.sql) current: now and every 15 minutes, 30 s after the copies, it replaces the rows
-- of each transcript agent.entries shows changed in the last 30 minutes or not in the table yet (at boot, all of them; a
-- literal list, so the scan reads only those files), recomputes is_repeat over the whole table, then rebuilds the BM25
-- index from that step's receipt. Nothing changed, no post.
WITH program AS (
    SELECT $refresh$
WITH transcript AS (
    SELECT path, modified FROM dev.agent.entries WHERE reader = 'read_json'
), changed AS (
    SELECT list(quote_literal(path)) AS files FROM (
        SELECT path FROM transcript WHERE modified >= now()::TIMESTAMP - INTERVAL 30 MINUTE   -- twice the cron period
        UNION
        SELECT path FROM transcript ANTI JOIN stream.main.blocks b ON b.file_path = transcript.path)
), window_step AS (
    SELECT array_agg(selfdispatch(tera_render($w$
CREATE OR REPLACE TABLE stream.main.blocks AS
SELECT * EXCLUDE (is_repeat),
       uuid IS NOT NULL AND file_path IS DISTINCT FROM arg_min(file_path, (timestamp, file_path)) OVER (PARTITION BY uuid) AS is_repeat
FROM (SELECT * FROM stream.main.blocks WHERE file_path NOT IN ({{ files | join(sep=", ") }})
      UNION ALL BY NAME
      SELECT * FROM stream.main.parsed WHERE file_path IN ({{ files | join(sep=", ") }}))
$w$, changed::JSON, autoescape := false))) AS receipts
    FROM changed WHERE len(files) > 0
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

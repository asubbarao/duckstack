-- Fills and keeps stream.blocks (blocks.sql) current: now and every 15 minutes, 30 s after the copies. Each transcript
-- agent.entries shows changed in the last 30 minutes or not in the table yet (at boot, all of them) is parsed again, 100
-- transcripts a post, in order: each post replaces the table with its other rows plus those transcripts' parse (a literal
-- list, so the scan reads only those files), so memory follows the batch, not the corpus (the whole corpus in one
-- statement outgrew 16 GB on 2026-10-21). Then is_repeat is set from uuid, file, line and timestamp alone, and the BM25
-- index is rebuilt, each step from the receipts of the one before. Nothing changed, no post.
WITH program AS (
    SELECT $refresh$
WITH transcript AS (
    SELECT path, modified FROM dev.agent.entries WHERE reader = 'read_json'
), stale AS (
    SELECT path FROM transcript WHERE modified >= now()::TIMESTAMP - INTERVAL 30 MINUTE   -- twice the cron period
    UNION
    SELECT path FROM transcript ANTI JOIN stream.main.blocks b ON b.file_path = transcript.path
), numbered AS (
    SELECT path, (row_number() OVER (ORDER BY path) - 1) // 100 AS batch FROM stale
), batches AS (
    SELECT batch, string_agg(quote_literal(path), ', ') AS files FROM numbered GROUP BY batch
), rendered AS (
    SELECT batch, tera_render($w$
CREATE OR REPLACE TABLE stream.main.blocks AS
SELECT * FROM stream.main.blocks WHERE file_path NOT IN ({{ files }})
UNION ALL BY NAME
SELECT *, false AS is_repeat FROM stream.main.parsed WHERE file_path IN ({{ files }})
$w$, b::JSON, autoescape := false) AS sql
    FROM batches b
), batch_step AS (
    SELECT array_agg(selfdispatch(sql) ORDER BY batch) AS receipts FROM rendered
), repeat_step AS (
    SELECT array_agg(selfdispatch($r$
CREATE OR REPLACE TABLE stream.main.blocks AS
WITH first_copy AS (
    SELECT uuid, arg_min((file_path, line), (timestamp, file_path, line)) AS first_line
    FROM stream.main.blocks WHERE uuid IS NOT NULL GROUP BY uuid
)
SELECT b.* REPLACE (b.uuid IS NOT NULL AND f.first_line IS DISTINCT FROM (b.file_path, b.line) AS is_repeat)
FROM stream.main.blocks b LEFT JOIN first_copy f USING (uuid)
$r$)) AS receipts
    FROM batch_step WHERE list_bool_or([r.status = 200 FOR r IN receipts])
), index_step AS (
    SELECT array_agg(selfdispatch($p$PRAGMA create_fts_index('stream.main.blocks', 'block_key', 'message_content', overwrite = 1)$p$)) AS receipts
    FROM repeat_step CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200
)
SELECT r.* FROM batch_step CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL SELECT r.* FROM repeat_step CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL SELECT r.* FROM index_step CROSS JOIN UNNEST(receipts) AS t(r);
$refresh$ AS sql
), posted AS (
    SELECT sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY sql
)
SELECT cron(sql, '30 */15 * * * *') AS job, r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

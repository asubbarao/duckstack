-- video_frames.sql: watch a video as rows, on dev. Pass one samples the whole video at a base rate; `scenes` splits
-- the frames where the picture moves; pass two re-samples the busiest scenes at a high rate, one statement per scene.
-- Every dispatched statement writes its frames to <out_dir>/frames_<slice>.parquet; `scenes` reads them all.
-- Edit the literals (video path, frames dir, rates) and run each statement through the dev MCP `execute` tool.
-- Silent screen recordings have no audio track; for sound, INSTALL whisper FROM community and join
-- whisper_transcribe_segments(path) to scenes on time.
-- Verified on dev 2026-10-17 on a generated 6 s, 3-scene 320x240 clip: pass one 12 frames, the scene query found
-- the 3 scenes, pass two re-sampled the 2 busy ones at 10 fps (21 + 20 frames). The view body was run as a SELECT.
INSTALL pic2vec FROM community;
LOAD pic2vec;

-- Pass one: the whole video at 2 fps.
WITH video AS (
    SELECT '/abs/path/help.mov' AS video, '/abs/scratch/help_frames' AS out_dir, 'all' AS slice,
           2 AS fps, 1400 AS width, 0 AS start, -1 AS "end", 0.8 AS quality, 'frames_cmd' AS sql_tag
), rendered AS (
    SELECT tera_render('video_frames.tera', v::JSON, autoescape := false,
                       template_path := '/Users/aloksubbarao/duckdb-skills/skills/tera/references/*.tera') AS sql
    FROM video AS v
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

-- A scene starts where the perceptual hash moves 10 bits or more against the previous frame.
CREATE OR REPLACE VIEW scenes AS
WITH frames AS (
    SELECT * FROM read_parquet('/abs/scratch/help_frames/frames_*.parquet')
), changes AS (
    SELECT *, pic_hamming(phash, lag(phash) OVER (ORDER BY second)) AS bits_changed FROM frames
), numbered AS (
    SELECT *, sum(CASE WHEN bits_changed IS NULL THEN 1 WHEN bits_changed >= 10 THEN 1 ELSE 0 END) OVER (ORDER BY second) AS scene
    FROM changes
)
SELECT scene, min(second) AS starts, max(second) AS ends, arg_max(path, second) AS settled_frame,
       len(array_agg(path)) AS frames, max(bits_changed) AS most_bits_changed
FROM numbered GROUP BY scene;

-- Pass two: the 20 busiest scenes (16 bits or more) again at 10 fps; their files join the same glob, so `scenes` sees them.
WITH busy AS (
    SELECT '/abs/path/help.mov' AS video, '/abs/scratch/help_frames' AS out_dir, scene AS slice,
           10 AS fps, 1400 AS width, starts AS start, ends + 0.5 AS "end", 0.8 AS quality, 'frames_cmd' AS sql_tag
    FROM scenes WHERE most_bits_changed >= 16 ORDER BY most_bits_changed DESC LIMIT 20
), rendered AS (
    SELECT tera_render('video_frames.tera', b::JSON, autoescape := false,
                       template_path := '/Users/aloksubbarao/duckdb-skills/skills/tera/references/*.tera') AS sql
    FROM busy AS b
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

SELECT scene, starts, ends, round(ends - starts, 1) AS seconds_on_screen, frames, most_bits_changed, settled_frame
FROM scenes ORDER BY scene;

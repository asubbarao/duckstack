-- video_frames.sql: watch a video as rows, on dev, in one query. Pass one samples the whole video at a base rate; a
-- scene starts where the perceptual hash moves scene_bits or more against the previous frame; pass two re-samples the
-- 20 busiest scenes (busy_bits or more) at busy_fps, one statement per scene, built from pass one's rows. The frames
-- come back in the receipts; only the JPEGs are written, to out_dir. The result is one row per scene over both passes.
-- Edit the first CTE and run it through the dev MCP `query` tool.
-- Silent screen recordings have no audio track; for sound, INSTALL whisper FROM community and join
-- whisper_transcribe_segments(path) to the scenes on time.
-- Verified on dev 2026-10-18 on the first 40 s of a screen recording at 320 px: 12 scenes over 255 frames, the same as
-- the version before it.
INSTALL pic2vec FROM community;
LOAD pic2vec;

WITH video AS (            -- every value, once: the video, the base pass, what counts as a scene and a busy scene
    SELECT '/abs/path/help.mov' AS video, '/abs/scratch/help_frames' AS out_dir,
           2 AS fps, 1400 AS width, 0 AS start, -1 AS "end", 0.8 AS quality, 'frames_cmd' AS sql_tag,
           10 AS scene_bits, 16 AS busy_bits, 10 AS busy_fps
), pass_one AS (           -- the video row stays beside its receipt
    SELECT *, array_agg(selfdispatch(tera_render('video_frames.tera', v::JSON, autoescape := false,
               template_path := '/Users/aloksubbarao/duckdb-skills/skills/tera/references/*.tera'))) AS receipts
    FROM video AS v GROUP BY ALL
), pass_one_frames AS (
    SELECT * EXCLUDE (receipts, frame), (frame ->> 'second')::DOUBLE AS second, frame ->> 'path' AS frame_path,
           (frame ->> 'phash')::BIGINT AS phash
    FROM pass_one CROSS JOIN UNNEST(receipts) AS t(receipt) CROSS JOIN UNNEST(receipt.body::JSON[]) AS f(frame)
), pass_one_scenes AS (
    SELECT *, sum(CASE WHEN bits IS NULL THEN 1 WHEN bits >= scene_bits THEN 1 ELSE 0 END) OVER (ORDER BY second) AS scene
    FROM (SELECT *, pic_hamming(phash, lag(phash) OVER (ORDER BY second)) AS bits FROM pass_one_frames)
), busy AS (               -- one row per busy scene: the video row with the busy rate and that scene's span
    SELECT video, out_dir, busy_fps AS fps, width, min(second) AS start, max(second) + 0.5 AS "end", quality, sql_tag,
           scene_bits, max(bits) AS scene_bits_changed
    FROM pass_one_scenes GROUP BY video, out_dir, busy_fps, width, quality, sql_tag, scene_bits, busy_bits, scene
    HAVING max(bits) >= busy_bits
), pass_two AS (
    SELECT *, array_agg(selfdispatch(tera_render('video_frames.tera', b::JSON, autoescape := false,
               template_path := '/Users/aloksubbarao/duckdb-skills/skills/tera/references/*.tera'))) AS receipts
    FROM (SELECT * FROM busy ORDER BY scene_bits_changed DESC LIMIT 20) AS b GROUP BY ALL   -- the 20 busiest; LIMIT takes no column
), frames AS (
    SELECT second, frame_path, phash, scene_bits FROM pass_one_frames
    UNION ALL
    SELECT (frame ->> 'second')::DOUBLE, frame ->> 'path', (frame ->> 'phash')::BIGINT, scene_bits
    FROM pass_two CROSS JOIN UNNEST(receipts) AS t(receipt) CROSS JOIN UNNEST(receipt.body::JSON[]) AS f(frame)
), numbered AS (
    SELECT *, sum(CASE WHEN bits IS NULL THEN 1 WHEN bits >= scene_bits THEN 1 ELSE 0 END) OVER (ORDER BY second) AS scene
    FROM (SELECT *, pic_hamming(phash, lag(phash) OVER (ORDER BY second)) AS bits FROM frames)
)
SELECT scene, min(second) AS starts, max(second) AS ends, round(max(second) - min(second), 1) AS seconds_on_screen,
       len(array_agg(frame_path)) AS frames, max(bits) AS most_bits_changed, arg_max(frame_path, second) AS settled_frame
FROM numbered GROUP BY scene ORDER BY scene;

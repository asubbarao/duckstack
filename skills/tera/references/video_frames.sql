-- video_frames.sql: a video as one row per scene, in one query on dev (run it with the dev MCP `query` tool; every value
-- is in the first CTE). Pass one samples the whole video at fps; a scene starts where the perceptual hash moves scene_bits
-- or more; pass two re-samples the busy_scenes busiest scenes (busy_bits or more) at busy_fps, one statement per scene.
-- Frames come back in the receipts; only the JPEGs are written, to out_dir. For sound, join whisper_transcribe_segments.
-- Verified on dev 2026-10-21, first 40 s of a screen recording at 320 px: 12 scenes over 255 frames, as before.
INSTALL pic2vec FROM community;
LOAD pic2vec;

WITH video AS (            -- every value, once: the video, the base pass, what counts as a scene and a busy scene
    SELECT '/abs/path/help.mov' AS video, '/abs/scratch/help_frames' AS out_dir,
           2 AS fps, 1400 AS width, 0 AS start, -1 AS "end", 0.8 AS quality, 'frames_cmd' AS sql_tag,
           10 AS scene_bits, 16 AS busy_bits, 10 AS busy_fps, 20 AS busy_scenes
), pass_one_statements AS (
    SELECT *, tera_render('video_frames.tera', v::JSON, autoescape := false,
               template_path := '/Users/aloksubbarao/duckdb-skills/skills/tera/references/*.tera') AS sql
    FROM video AS v
), pass_one AS (           -- the video row stays beside its receipts
    SELECT * EXCLUDE (sql), array_agg(selfdispatch(sql)) AS receipts FROM pass_one_statements GROUP BY ALL
), pass_one_frames AS (
    SELECT * EXCLUDE (receipts, receipt, frame), (frame ->> 'second')::DOUBLE AS second, frame ->> 'path' AS frame_path,
           (frame ->> 'phash')::BIGINT AS phash, pic_hamming(phash, lag(phash) OVER (ORDER BY second)) AS bits
    FROM pass_one CROSS JOIN UNNEST(receipts) AS t(receipt) CROSS JOIN UNNEST(receipt.body::JSON[]) AS f(frame)
), pass_one_scenes AS (
    SELECT *, sum((coalesce(bits, scene_bits) >= scene_bits)::INT) OVER (ORDER BY second) AS scene FROM pass_one_frames
), busy AS (               -- one row per busy scene: the video row at the busy rate over that scene's span, ranked
    SELECT video, out_dir, busy_fps AS fps, width, quality, sql_tag, scene_bits, busy_bits, busy_scenes, scene,
           min(second) AS start, max(second + 1.0 / pass_one_scenes.fps) AS "end", max(bits) AS scene_bits_changed,
           rank() OVER (ORDER BY max(bits) DESC) AS busy_rank
    FROM pass_one_scenes GROUP BY ALL HAVING max(bits) >= busy_bits
), pass_two_statements AS (
    SELECT scene_bits, tera_render('video_frames.tera', b::JSON, autoescape := false,
               template_path := '/Users/aloksubbarao/duckdb-skills/skills/tera/references/*.tera') AS sql
    FROM busy AS b WHERE busy_rank <= busy_scenes
), pass_two AS (
    SELECT scene_bits, array_agg(selfdispatch(sql)) AS receipts FROM pass_two_statements GROUP BY scene_bits
), frames AS (             -- pass two's frames, parsed like pass one's, beside them by name
    SELECT second, frame_path, phash, scene_bits FROM pass_one_frames
    UNION ALL BY NAME
    SELECT (frame ->> 'second')::DOUBLE AS second, frame ->> 'path' AS frame_path, (frame ->> 'phash')::BIGINT AS phash,
           scene_bits
    FROM pass_two CROSS JOIN UNNEST(receipts) AS t(receipt) CROSS JOIN UNNEST(receipt.body::JSON[]) AS f(frame)
), frame_bits AS (
    SELECT *, pic_hamming(phash, lag(phash) OVER (ORDER BY second)) AS bits FROM frames
), numbered AS (
    SELECT *, sum((coalesce(bits, scene_bits) >= scene_bits)::INT) OVER (ORDER BY second) AS scene FROM frame_bits
)
SELECT scene, min(second) AS starts, max(second) AS ends, round(ends - starts, 1) AS seconds_on_screen,
       array_agg(frame_path ORDER BY second) AS frame_paths, len(frame_paths) AS frames, max(bits) AS most_bits_changed,
       arg_max(frame_path, second) AS settled_frame
FROM numbered GROUP BY scene ORDER BY scene;

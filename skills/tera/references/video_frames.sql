-- video_frames.sql: a video as one row per scene, in one query on dev (run it with the dev MCP `query` tool; every value
-- is in the first CTE). Pass one samples the whole video at fps; a scene starts where the perceptual hash moves scene_bits
-- or more; pass two re-samples the busy_scenes busiest scenes (busy_bits or more) at busy_fps, one statement per scene.
-- Frames come back in the receipts; only the JPEGs are written, to out_dir. For sound, join whisper_transcribe_segments.
-- Verified on dev 2026-10-21, first 40 s of a screen recording at 320 px: 12 scenes over 255 frames, as before.
INSTALL pic2vec FROM community;
LOAD pic2vec;

WITH video AS (            -- every value, once: the video, the base pass, what counts as a scene and a busy scene,
    SELECT '/abs/path/help.mov' AS video, '/abs/scratch/help_frames' AS out_dir,    -- and the template, read from its file
           2 AS fps, 1400 AS width, 0 AS start, -1 AS "end", 0.8 AS quality, 'frames_cmd' AS sql_tag,
           10 AS scene_bits, 16 AS busy_bits, 10 AS busy_fps, 20 AS busy_scenes, content AS template
    FROM read_text('/Users/aloksubbarao/duckdb-skills/skills/tera/references/video_frames.tera')
), pass_one_statements AS (
    SELECT *, tera_render(template, v::JSON, autoescape := false) AS sql FROM video AS v
), pass_one AS (           -- the video row stays beside its receipts
    SELECT * EXCLUDE (sql), array_agg(selfdispatch(sql)) AS receipts FROM pass_one_statements GROUP BY ALL
), pass_one_frames AS (
    SELECT * EXCLUDE (receipts, receipt, frame), (frame ->> 'second')::DOUBLE AS second, frame ->> 'path' AS frame_path,
           (frame ->> 'phash')::BIGINT AS phash, pic_hamming(phash, lag(phash) OVER (ORDER BY second)) AS bits
    FROM pass_one CROSS JOIN UNNEST(receipts) AS t(receipt) CROSS JOIN UNNEST(receipt.body::JSON[]) AS f(frame)
), pass_one_scenes AS (
    SELECT *, sum((coalesce(bits, scene_bits) >= scene_bits)::INT) OVER (ORDER BY second) AS scene FROM pass_one_frames
), busy AS (               -- one row per busy scene: the video row at the busy rate over that scene's span
    SELECT * EXCLUDE (fps, start, "end", second, frame_path, phash, bits), busy_fps AS fps, min(second) AS start,
           max(second + 1.0 / pass_one_scenes.fps) AS "end", max(bits) AS scene_bits_changed
    FROM pass_one_scenes GROUP BY ALL HAVING max(bits) >= busy_bits
), busiest AS (            -- the busy_scenes busiest, most movement first, as one ordered list
    SELECT array_agg(b ORDER BY scene_bits_changed DESC)[1:busy_scenes] AS scenes FROM busy AS b GROUP BY busy_scenes
), pass_two_statements AS (
    SELECT busy_scene, tera_render(busy_scene.template, busy_scene::JSON, autoescape := false) AS sql
    FROM busiest CROSS JOIN UNNEST(scenes) AS t(busy_scene)
), pass_two AS (           -- one array of posts; each busy scene's row stays beside its receipt
    SELECT array_agg({busy_scene: busy_scene, receipt: selfdispatch(sql)}) AS posts FROM pass_two_statements
), frames AS (             -- pass two's frames, parsed like pass one's, beside them by name
    SELECT second, frame_path, phash, scene_bits FROM pass_one_frames
    UNION ALL BY NAME
    SELECT (frame ->> 'second')::DOUBLE AS second, frame ->> 'path' AS frame_path, (frame ->> 'phash')::BIGINT AS phash,
           post.busy_scene.scene_bits AS scene_bits, post.busy_scene.scene AS busy_scene
    FROM pass_two CROSS JOIN UNNEST(posts) AS t(post) CROSS JOIN UNNEST(post.receipt.body::JSON[]) AS f(frame)
), frame_bits AS (
    SELECT *, pic_hamming(phash, lag(phash) OVER (ORDER BY second)) AS bits FROM frames
), numbered AS (
    SELECT *, sum((coalesce(bits, scene_bits) >= scene_bits)::INT) OVER (ORDER BY second) AS scene FROM frame_bits
), scenes AS (
    SELECT scene, min(second) AS starts, max(second) AS ends, round(ends - starts, 1) AS seconds_on_screen,
           array_agg(frame_path ORDER BY second) AS frame_paths, len(frame_paths) AS frames,
           max(bits) AS most_bits_changed, arg_max(frame_path, second) AS settled_frame
    FROM numbered GROUP BY scene
)
FROM scenes ORDER BY scene;

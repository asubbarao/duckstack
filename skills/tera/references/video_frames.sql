-- video_frames.sql: watch a video as rows, on dev, in one query. Pass one samples the whole video at a base rate; a
-- scene starts where the perceptual hash moves 10 bits or more against the previous frame; pass two re-samples the 20
-- busiest scenes (16 bits or more) at 10 fps, one statement per scene, built from pass one's receipts. The frames come
-- back in the receipts; only the JPEGs are written, to out_dir. The result is one row per scene over both passes.
-- Edit the literals (video path, frames dir, rates) and run it through the dev MCP `query` tool.
-- Silent screen recordings have no audio track; for sound, INSTALL whisper FROM community and join
-- whisper_transcribe_segments(path) to the scenes on time.
-- Verified on dev 2026-10-18 on the first 40 s of a screen recording at 320 px: 80 pass-one frames, 7 busy scenes
-- re-sampled (175 frames), 12 scenes over 255 frames, the same rows as the Parquet version it replaced (EXCEPT ALL 0 both ways).
INSTALL pic2vec FROM community;
LOAD pic2vec;

WITH video AS (
    SELECT '/abs/path/help.mov' AS video, '/abs/scratch/help_frames' AS out_dir,
           2 AS fps, 1400 AS width, 0 AS start, -1 AS "end", 0.8 AS quality, 'frames_cmd' AS sql_tag
), pass_one_rendered AS (
    SELECT tera_render('video_frames.tera', v::JSON, autoescape := false,
                       template_path := '/Users/aloksubbarao/duckdb-skills/skills/tera/references/*.tera') AS sql
    FROM video AS v
), pass_one_dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM pass_one_rendered
), pass_one AS (
    SELECT (frame ->> 'second')::DOUBLE AS second, frame ->> 'path' AS path, (frame ->> 'phash')::BIGINT AS phash
    FROM pass_one_dispatched CROSS JOIN UNNEST(receipts) AS t(receipt) CROSS JOIN UNNEST(receipt.body::JSON[]) AS f(frame)
), pass_one_changes AS (
    SELECT *, pic_hamming(phash, lag(phash) OVER (ORDER BY second)) AS bits_changed FROM pass_one
), pass_one_scenes AS (
    SELECT *, sum(CASE WHEN bits_changed IS NULL THEN 1 WHEN bits_changed >= 10 THEN 1 ELSE 0 END) OVER (ORDER BY second) AS scene
    FROM pass_one_changes
), busy AS (
    SELECT '/abs/path/help.mov' AS video, '/abs/scratch/help_frames' AS out_dir,
           10 AS fps, 1400 AS width, min(second) AS start, max(second) + 0.5 AS "end", 0.8 AS quality, 'frames_cmd' AS sql_tag
    FROM pass_one_scenes GROUP BY scene HAVING max(bits_changed) >= 16 ORDER BY max(bits_changed) DESC LIMIT 20
), pass_two_rendered AS (
    SELECT tera_render('video_frames.tera', b::JSON, autoescape := false,
                       template_path := '/Users/aloksubbarao/duckdb-skills/skills/tera/references/*.tera') AS sql
    FROM busy AS b
), pass_two_dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM pass_two_rendered
), frames AS (
    SELECT second, path, phash FROM pass_one
    UNION ALL
    SELECT (frame ->> 'second')::DOUBLE, frame ->> 'path', (frame ->> 'phash')::BIGINT
    FROM pass_two_dispatched CROSS JOIN UNNEST(receipts) AS t(receipt) CROSS JOIN UNNEST(receipt.body::JSON[]) AS f(frame)
), changes AS (
    SELECT *, pic_hamming(phash, lag(phash) OVER (ORDER BY second)) AS bits_changed FROM frames
), numbered AS (
    SELECT *, sum(CASE WHEN bits_changed IS NULL THEN 1 WHEN bits_changed >= 10 THEN 1 ELSE 0 END) OVER (ORDER BY second) AS scene
    FROM changes
), scenes AS (
    SELECT scene, min(second) AS starts, max(second) AS ends, arg_max(path, second) AS settled_frame,
           len(array_agg(path)) AS frames, max(bits_changed) AS most_bits_changed
    FROM numbered GROUP BY scene
)
SELECT scene, starts, ends, round(ends - starts, 1) AS seconds_on_screen, frames, most_bits_changed, settled_frame
FROM scenes ORDER BY scene;

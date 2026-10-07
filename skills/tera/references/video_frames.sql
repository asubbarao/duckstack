-- video_frames.sql: watch a video as rows. Pass one: sample the whole video at a base rate and split it into scenes.
-- Pass two: every scene whose picture moved a lot is re-sampled at a high rate, so fast motion is not lost; the
-- rate is a context value, and the second pass is the same template rendered once per busy scene (self-dispatch).
-- Run from any directory:
--   duckdb video.duckdb -cmd "SET VARIABLE video = '/abs/path.mov'" -f ~/duckdb-skills/skills/tera/references/video_frames.sql
-- Optional SET VARIABLE: out_dir, fps (2), width (1400), engine ('avfoundation' | 'ffmpeg'), scene_bits (10),
--   busy_bits (16: a scene that moved this much is re-sampled), busy_fps (10), max_busy_scenes (20).
-- Silent screen recordings have no audio track; for videos with sound, INSTALL whisper FROM community and join
-- whisper_transcribe_segments(path) to scenes on time.
-- Verified 2026-10-02, DuckDB 1.5.5, pic2vec 113ee24, avfoundation: an 8 min 41 s 3024x1654 recording at 2 fps,
-- width 1400 -> 1,043 frames in 40 s, 75 scenes; the second pass re-sampled the busy scenes at 10 fps.
INSTALL shellfs FROM community; INSTALL pic2vec FROM community; INSTALL tera FROM community;
LOAD tera;
LOAD pic2vec;
SET VARIABLE templates = '/Users/aloksubbarao/duckdb-skills/skills/tera/references/*.tera';
SET VARIABLE frames_dir = coalesce(getvariable('out_dir'), getvariable('video') || '.frames');

-- Pass one: the whole video at the base rate.
COPY (
  SELECT tera_render('video_frames.tera',
           json_object('video', getvariable('video'), 'out_dir', getvariable('frames_dir'),
                       'fps', coalesce(getvariable('fps'), 2), 'width', coalesce(getvariable('width'), 1400),
                       'engine', coalesce(getvariable('engine'), 'avfoundation'),
                       'table', 'frames', 'append', false, 'sql_tag', 'frames_cmd'),
           autoescape := false, template_path := getvariable('templates'))
) TO '/tmp/video_frames.pass1.sql' (FORMAT csv, HEADER false, QUOTE '', DELIMITER E'\x01');
.read /tmp/video_frames.pass1.sql

CREATE OR REPLACE MACRO scene_table() AS TABLE
WITH changes AS (
  SELECT *, pic_hamming(phash, lag(phash) OVER (ORDER BY second)) AS bits_changed FROM frames
), numbered AS (
  SELECT *, sum(CASE WHEN bits_changed IS NULL THEN 1 WHEN bits_changed >= coalesce(getvariable('scene_bits'), 10) THEN 1 ELSE 0 END)
            OVER (ORDER BY second) AS scene
  FROM changes
)
SELECT scene, min(second) AS starts, max(second) AS ends, arg_max(path, second) AS settled_frame, count(1) AS frames,
       max(bits_changed) AS most_bits_changed
FROM numbered GROUP BY scene;
CREATE OR REPLACE TABLE scenes AS FROM scene_table();

-- Pass two: busy scenes again at the high rate. One rendered statement per scene; rows append to the same table.
CREATE OR REPLACE TABLE busy AS
SELECT scene, starts, ends,
       tera_render('video_frames.tera',
         json_object('video', getvariable('video'), 'out_dir', getvariable('frames_dir'),
                     'fps', coalesce(getvariable('busy_fps'), 10), 'width', coalesce(getvariable('width'), 1400),
                     'engine', coalesce(getvariable('engine'), 'avfoundation'),
                     'start', starts, 'end', ends + 1.0 / coalesce(getvariable('fps'), 2),
                     'table', 'frames', 'append', true, 'sql_tag', 'frames_cmd'),
         autoescape := false, template_path := getvariable('templates')) AS statement
FROM scenes
WHERE most_bits_changed >= coalesce(getvariable('busy_bits'), 16)
ORDER BY most_bits_changed DESC
LIMIT coalesce(getvariable('max_busy_scenes'), 20);
COPY (SELECT statement FROM busy ORDER BY starts) TO '/tmp/video_frames.pass2.sql' (FORMAT csv, HEADER false, QUOTE '', DELIMITER E'\x01');
.read /tmp/video_frames.pass2.sql

-- Scenes again, now with the fine frames inside the busy ones; duplicate seconds from the two passes are kept apart by path.
CREATE OR REPLACE TABLE scenes AS FROM scene_table();
SELECT 'frames' AS what, count(1) AS n FROM frames UNION ALL SELECT 'scenes', count(1) FROM scenes UNION ALL SELECT 'busy scenes re-sampled', count(1) FROM busy;
SELECT scene, starts, ends, round(ends - starts, 1) AS seconds_on_screen, frames, most_bits_changed, settled_frame FROM scenes ORDER BY scene;

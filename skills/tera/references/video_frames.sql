-- video_frames.sql: watch a video as rows. Renders video_frames.tera, runs it, then splits the frames into scenes.
-- Silent screen recordings have no audio track; for videos with sound, transcribe with the whisper extension
-- (INSTALL whisper FROM community; whisper_transcribe_segments(path)) and join segments to scenes on time.
-- Run from any directory:  duckdb video.duckdb -cmd "SET VARIABLE video = '/abs/path.mov'" -f ~/duckdb-skills/skills/tera/references/video_frames.sql
-- Verified 2026-10-02, DuckDB 1.5.5, pic2vec 113ee24, engine avfoundation: an 8 min 41 s 3024x1654 recording,
-- 2 fps, width 1400 -> 1,043 frames in 40 s; 565 frames identical to the previous (Hamming 0); a 10-bit
-- threshold gave 75 scenes. The ffmpeg branch is written but was not run (ffmpeg was not installed).
INSTALL shellfs FROM community; INSTALL pic2vec FROM community; INSTALL tera FROM community;
LOAD tera;
COPY (
  SELECT tera_render('video_frames.tera',
           json_object('video', getvariable('video'),
                       'out_dir', coalesce(getvariable('out_dir'), getvariable('video') || '.frames'),
                       'fps', coalesce(getvariable('fps'), 2),
                       'width', coalesce(getvariable('width'), 1400),
                       'engine', coalesce(getvariable('engine'), 'avfoundation'),
                       'table', 'frames', 'sql_tag', 'frames_cmd'),
           autoescape := false,
           template_path := '/Users/aloksubbarao/duckdb-skills/skills/tera/references/*.tera')
) TO '/tmp/video_frames.rendered.sql' (FORMAT csv, HEADER false, QUOTE '', DELIMITER E'\x01');
.read /tmp/video_frames.rendered.sql
LOAD pic2vec;
-- A scene starts where the perceptual hash moves by scene_bits or more; its settled frame is its last one.
CREATE OR REPLACE TABLE scenes AS
WITH changes AS (
  SELECT *, pic_hamming(phash, lag(phash) OVER (ORDER BY second)) AS bits_changed FROM frames
), numbered AS (
  SELECT *, sum(CASE WHEN bits_changed IS NULL THEN 1 WHEN bits_changed >= coalesce(getvariable('scene_bits'), 10) THEN 1 ELSE 0 END)
            OVER (ORDER BY second) AS scene
  FROM changes
)
SELECT scene, min(second) AS starts, max(second) AS ends, arg_max(path, second) AS settled_frame, count(1) AS frames
FROM numbered GROUP BY scene;
SELECT scene, starts, ends, round(ends - starts, 1) AS seconds_on_screen, settled_frame FROM scenes ORDER BY scene;

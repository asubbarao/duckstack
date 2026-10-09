-- video_frames.sql: watch a video as rows, on dev. Pass one samples the whole video at a base rate and splits it into
-- scenes; pass two re-samples every scene whose picture moved a lot at a high rate, one rendered statement per busy
-- scene posted to dev's /sql (self-dispatch). Edit the literals (video path, frames dir, rates) and run each
-- statement through the dev MCP `execute` tool, or post the whole body to http://127.0.0.1:9495/sql.
-- Silent screen recordings have no audio track; for videos with sound, INSTALL whisper FROM community and join
-- whisper_transcribe_segments(path) to scenes on time.
-- Verified 2026-10-02, DuckDB 1.5.5, pic2vec 113ee24, avfoundation: an 8 min 41 s 3024x1654 recording at 2 fps,
-- width 1400 -> 1,043 frames in 40 s, 75 scenes; the second pass re-sampled the busy scenes at 10 fps.
INSTALL pic2vec FROM community; LOAD pic2vec;

-- Pass one: the whole video at 2 fps. The rendered statement creates `frames` on dev.
CREATE OR REPLACE TABLE video_pass1 AS
SELECT from_json(http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'},
         json_object('sql', 'CREATE OR REPLACE TABLE frames AS ' || tera_render('video_frames.tera',
           json_object('video', '/abs/path/help.mov', 'out_dir', '/abs/scratch/help_frames',
                       'fps', 2, 'width', 1400, 'engine', 'avfoundation', 'sql_tag', 'frames_cmd'),
           autoescape := false, template_path := '/Users/aloksubbarao/duckdb-skills/skills/tera/references/*.tera'))),
         '{"status": "INTEGER", "body": "VARCHAR"}') AS receipt;

-- A scene starts where the perceptual hash moves 10 bits or more against the previous frame.
CREATE OR REPLACE VIEW scenes AS
WITH changes AS (
  SELECT *, pic_hamming(phash, lag(phash) OVER (ORDER BY second)) AS bits_changed FROM frames
), numbered AS (
  SELECT *, sum(CASE WHEN bits_changed IS NULL THEN 1 WHEN bits_changed >= 10 THEN 1 ELSE 0 END) OVER (ORDER BY second) AS scene
  FROM changes
)
SELECT scene, min(second) AS starts, max(second) AS ends, arg_max(path, second) AS settled_frame,
       len(array_agg(path)) AS frames, max(bits_changed) AS most_bits_changed
FROM numbered GROUP BY scene;

-- Pass two: the 20 busiest scenes (16 bits or more) again at 10 fps; rows append to `frames`, so `scenes` sees them.
CREATE OR REPLACE TABLE video_pass2 AS
WITH busy AS (
  SELECT scene, starts, ends,
         'INSERT INTO frames ' || tera_render('video_frames.tera',
           json_object('video', '/abs/path/help.mov', 'out_dir', '/abs/scratch/help_frames',
                       'fps', 10, 'width', 1400, 'engine', 'avfoundation',
                       'start', starts, 'end', ends + 0.5, 'sql_tag', 'frames_cmd'),
           autoescape := false, template_path := '/Users/aloksubbarao/duckdb-skills/skills/tera/references/*.tera') AS statement
  FROM scenes WHERE most_bits_changed >= 16 ORDER BY most_bits_changed DESC LIMIT 20
)
SELECT scene, starts, ends,
       from_json(http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', statement)),
                 '{"status": "INTEGER", "body": "VARCHAR"}') AS receipt
FROM busy;

SELECT scene, starts, ends, round(ends - starts, 1) AS seconds_on_screen, frames, most_bits_changed, settled_frame
FROM scenes ORDER BY scene;

---
name: watch-video
description: >
  Watch a video or screen recording as rows: sample frames at a chosen rate through a Tera-rendered
  read_csv pipe, hash and embed each frame with `pic2vec`, split the stream into scenes where the picture
  changes, read only the settled frame of each scene with the Read tool, and transcribe any audio with
  `whisper`. Use when asked to watch, read, summarize or check a video, a demo, a Loom or a screen
  recording. Not for a single image (use pic2vec directly) or for live video.
argument-hint: "<file.mov|mp4> [what you want to know]"
allowed-tools: Bash, Read, mcp__dev__query_with_limit, mcp__dev__shellfs
---

# Watch a video as rows

A video is a stream of frames plus an audio track. Frames become rows through one Tera template; scenes
come from the perceptual hash moving; the model only ever looks at one settled frame per scene. Verified
2026-10-02 on DuckDB 1.5.5 with an 8 min 41 s, 3024x1654 screen recording: 1,043 frames at 2 per second in
40 s, 75 scenes, 15 frames actually read to understand the whole video.

## 1. Frames and scenes

```bash
duckdb video.duckdb \
  -cmd "SET VARIABLE video = '/abs/path/help.mov'" \
  -cmd "SET VARIABLE out_dir = '/abs/scratch/help_frames'" \
  -f ~/duckdb-skills/skills/tera/references/video_frames.sql
```

What it does, and the knobs (all `SET VARIABLE`, all optional except `video`):

| Variable | Default | Meaning |
|---|---|---|
| `fps` | 2 | frames sampled per second; 2 catches every screen change in a demo, 0.5 is enough for slides |
| `width` | 1400 | frame width in pixels; 1400 keeps UI text readable for the Read tool |
| `engine` | avfoundation | macOS built-in, nothing to install; `ffmpeg` if ffmpeg is on PATH (branch written, not yet run) |
| `scene_bits` | 10 | a scene starts when the perceptual hash moves this many bits; 4 is sensitive, 16 coarse |
| `out_dir` | `<video>.frames` | where the JPEGs go |
| `busy_bits` | 16 | a scene whose hash moved this much gets a second pass |
| `busy_fps` | 10 | the rate of that second pass, so fast motion inside a busy scene is not lost |
| `max_busy_scenes` | 20 | how many busy scenes get the second pass, most movement first |

Two passes: the whole video at `fps`, then each busy scene re-rendered from the same template with `start`,
`end` and `busy_fps` (one rendered statement per scene, appended to the same table). Every bash flag is a
context value of the template: `ffmpeg_input_flags`, `ffmpeg_filters`, `ffmpeg_output_flags`, `quality`,
`width`, so a different capture is a different context, never a different program. Verified: the second pass
at 10 fps over the 5 busiest scenes added 330 frames in 25 s, same 75 scenes.

The template is `~/duckdb-skills/skills/tera/references/video_frames.tera`. It renders a `read_csv` over a
pipe: the frame writer prints `second,path` per frame as it writes it, `read_csv` consumes the stream, and
`pic_phash(path)` runs per row as it arrives. A slice (`start`, `end`) at any `fps` is the same template. Tables left behind: `frames(second, path, phash)` and
`scenes(scene, starts, ends, settled_frame, frames)`.

## 2. Read the settled frames, longest scenes first

```sql
SELECT scene, starts, ends, round(ends - starts, 1) AS seconds_on_screen, settled_frame
FROM scenes WHERE ends - starts >= 3 ORDER BY starts;
```

Read each `settled_frame` with the Read tool. A scene that stayed up for seconds is content; half-second
scenes are transitions, scrolls and typing. For a 9-minute demo that is 15 to 25 images.

## 3. Audio, when there is one

```sql
INSTALL whisper FROM community; LOAD whisper;
SELECT * FROM whisper_audio_info('/abs/path/talk.mp4');          -- errors with "No audio stream" on silent recordings
SELECT * FROM whisper_transcribe_segments('/abs/path/talk.mp4');  -- start, end, text per segment
```

The `base.en` model is downloaded (`whisper_list_models()`); `whisper_download_model('small.en')` for better
accuracy. Join segments to scenes on time: `segment.start BETWEEN scene.starts AND scene.ends`.

## 4. pic2vec, what is verified

`INSTALL pic2vec FROM community; LOAD pic2vec;` (v0.1.0, bundles a 192-d ViT-T image model, no download).

| Function | Verified use |
|---|---|
| `pic_phash(path)` | perceptual hash as text; identical frames hash identical (565 of 1,043 did) |
| `pic_hamming(h1, h2)` | bits that differ between two hashes; the scene signal |
| `pic_load_bundled()` then `pic_embed(path)` | 192-d FLOAT[] embedding; two different wizard screens scored 0.87 similarity, the same frame 1.0 |
| `pic_similarity(e1, e2)`, `pic_distance`, `pic_match(path, path)` | compare embeddings or paths directly |
| `pic_image_info(path)` | width, height, channels, format |
| `pic_diff_ascii(a, b)`, `pic_diff_patches`, `pic_diff_heatmap(a, b, out, ...)` | which patches of two frames differ; heatmap writes an image |
| `pic_dedupe(a, b)` | near-duplicate test |

Not yet used: `pic_embed_blob` on bytes, `pic_download_model` for other models. Embeddings are for
"find the scene that looks like this screen" (`ORDER BY pic_similarity(...) DESC`); the hash is enough for
scene detection and is 20x cheaper.

## Rules

- Read frames, never the video; the Read tool shows an image, the model does not take motion or sound.
- Frames are scratch: write them under the session scratchpad or next to the video, never into a repo.
- A screen recording of client data is client data: counts and names in anything written, no values.
- No `.sh` and no Python in the path: the frame writer is a heredoc inside the Tera template, run by `read_csv`.
- The ffmpeg branch of the template is written but unverified; the first run with `engine = 'ffmpeg'`
  should be checked against the avfoundation frame count and then noted here.

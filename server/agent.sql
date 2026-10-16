-- Agent transcripts (Claude Code ~/.claude/projects, Codex ~/.codex), read natively, one Parquet per session under
-- ~/.duck/lake/agent at the session's own path.
-- agent.entries: PR #1576's entries shape over one find of the transcript roots and the store, with hostfs columns.
-- A session is a Claude transcript <project>/<stem>.jsonl plus its <project>/<stem>/subagents/*.jsonl, or one Codex
-- rollout file; its stored copy is <store><session>.parquet. Roots that do not exist are skipped, so a machine without
-- transcripts lists nothing, copies nothing and never posts agent.lines (read_parquet fails on an empty file list).
-- read_json keeps every top-level field as a column of JSON (maximum_depth 1, map inference off): the same shape in
-- every file. Map inference turns a project's ~170 top-level fields into one MAP; inferred deeper, a field is a STRUCT
-- in one file and a MAP in another, which union_by_name cannot merge. maximum_object_size 32 MB fits the largest line
-- (~21 MB); the reader's buffers are twice it per thread.
CREATE SCHEMA IF NOT EXISTS agent;
CREATE OR REPLACE VIEW agent.entries AS
SELECT path, parse_dirpath(path) AS parent, file_name(path) AS name, parse_filename(path, true) AS stem, file_extension(path) AS ext,
       file_size(path) AS bytes, file_last_modified(path) AS modified,
       CASE WHEN ext = '.parquet' THEN 'read_parquet' ELSE 'read_json' END AS reader,
       CASE WHEN reader = 'read_parquet' THEN split_part(path, '/.duck/lake/agent', 2)[:-9]
            WHEN file_name(parent) = 'subagents' THEN parse_dirpath(parent)
            ELSE parent || '/' || stem END AS session
FROM (SELECT rtrim(content, e'\n') AS path
      FROM read_lines($c$for d in ~/.claude/projects ~/.codex/sessions ~/.codex/archived_sessions ~/.duck/lake/agent; do [ -d "$d" ] && find "$d" -type f \( -name '*.jsonl*' -o -name '*.parquet' \); done; true |$c$));
-- agent.titles: Codex thread names from ~/.codex/session_index.jsonl; id is the session id in the rollout file name.
CREATE OR REPLACE VIEW agent.titles AS
SELECT id, thread_name AS title, updated_at::TIMESTAMPTZ AS updated_at FROM read_json(getenv('HOME') || '/.codex/session_index.jsonl', format := 'newline_delimited');
-- Each session with a file newer than its stored copy (or none stored) is copied whole, one post per session; the posts
-- of one SELECT run at the same time. Boot and the 5-minute cron run the same two statements: an empty store takes
-- 980 sessions (3.6 GB, ~45 s; posts that fail are retried by the next run), a 5-minute run the few active sessions
-- (~13 MB, 0.5 s). A replaced file is written as tmp_<name> and renamed, and agent.lines is posted after the copies with
-- the stored files' literal list, so it never reads a partial file. It keeps the lines whose transcript still exists.
SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', printf($s$SELECT content FROM read_text('mkdir -p %s |');
COPY (SELECT * FROM read_json([%s], format := 'newline_delimited', maximum_depth := 1, map_inference_threshold := -1, sample_size := -1,
      maximum_object_size := 33554432, ignore_errors := true, union_by_name := true, filename := 'transcript')) TO '%s' (FORMAT parquet)$s$,
      parse_dirpath(stored), files, stored))).status
FROM (SELECT t.session, '~/.duck/lake/agent' || t.session || '.parquet' AS stored, string_agg('$q$' || t.path || '$q$', ', ') AS files
      FROM agent.entries t LEFT JOIN agent.entries s ON s.reader = 'read_parquet' AND s.session = t.session
      WHERE t.reader = 'read_json'
      GROUP BY t.session HAVING bool_or(t.modified > coalesce(s.modified, '-infinity'::TIMESTAMP)));
SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', printf($s$CREATE OR REPLACE VIEW agent.lines AS
SELECT * FROM read_parquet([%s], union_by_name := true) SEMI JOIN agent.entries e ON e.path = transcript$s$, files))).status
FROM (SELECT string_agg('$q$' || path || '$q$', ', ') AS files FROM agent.entries WHERE reader = 'read_parquet' AND NOT starts_with(name, 'tmp_'))
WHERE files IS NOT NULL;
SELECT cron($$SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', printf($s$SELECT content FROM read_text('mkdir -p %s |');
COPY (SELECT * FROM read_json([%s], format := 'newline_delimited', maximum_depth := 1, map_inference_threshold := -1, sample_size := -1,
      maximum_object_size := 33554432, ignore_errors := true, union_by_name := true, filename := 'transcript')) TO '%s' (FORMAT parquet)$s$,
      parse_dirpath(stored), files, stored))).status
FROM (SELECT t.session, '~/.duck/lake/agent' || t.session || '.parquet' AS stored, string_agg('$q$' || t.path || '$q$', ', ') AS files
      FROM agent.entries t LEFT JOIN agent.entries s ON s.reader = 'read_parquet' AND s.session = t.session
      WHERE t.reader = 'read_json'
      GROUP BY t.session HAVING bool_or(t.modified > coalesce(s.modified, '-infinity'::TIMESTAMP)));
SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', printf($s$CREATE OR REPLACE VIEW agent.lines AS
SELECT * FROM read_parquet([%s], union_by_name := true) SEMI JOIN agent.entries e ON e.path = transcript$s$, files))).status
FROM (SELECT string_agg('$q$' || path || '$q$', ', ') AS files FROM agent.entries WHERE reader = 'read_parquet' AND NOT starts_with(name, 'tmp_'))
WHERE files IS NOT NULL$$, '0 */5 * * * *');

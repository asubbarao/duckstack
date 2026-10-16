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
-- One refresh program, run once now and every five minutes. Each session with a file newer than its stored copy (or
-- none stored) is copied whole, one post per session, run at the same time: an empty store takes 980 sessions (3.6 GB,
-- ~45 s; failed posts are retried by the next run), a 5-minute run the few active ones (~13 MB, 0.5 s). agent.lines is
-- rebound after the copies with the stored files' literal list, so it never reads a partial file. No changed session
-- means no rows, so nothing is posted.
WITH program AS (
    SELECT $refresh$
WITH c AS (
    SELECT t.session, getenv('HOME') || '/.duck/lake/agent' || t.session || '.parquet' AS target,
           quote_literal(target) AS stored, quote_literal(parse_dirpath(target)) AS directory,
           list(quote_literal(t.path)) AS files
    FROM agent.entries t LEFT JOIN agent.entries s ON s.reader = 'read_parquet' AND s.session = t.session
    WHERE t.reader = 'read_json'
    GROUP BY t.session HAVING bool_or(t.modified > coalesce(s.modified, '-infinity'::TIMESTAMP))
), statements AS (
    SELECT tera_render($copy$
SELECT content FROM read_text($cmd$mkdir -p {{ directory }} |$cmd$);
COPY (
    SELECT * FROM read_json([{{ files | join(sep=", ") }}],
        format := 'newline_delimited', maximum_depth := 1, map_inference_threshold := -1, sample_size := -1,
        maximum_object_size := 33554432, ignore_errors := true, union_by_name := true, filename := 'transcript')
) TO {{ stored }} (FORMAT parquet);
$copy$, c::JSON, autoescape := false) AS sql FROM c
), posted AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM statements
)
SELECT r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

WITH c AS (
    SELECT list(quote_literal(path)) AS files FROM agent.entries WHERE reader = 'read_parquet' AND NOT starts_with(name, 'tmp_')
), statements AS (
    SELECT tera_render($view$
CREATE OR REPLACE VIEW agent.lines AS
SELECT * FROM read_parquet([{{ files | join(sep=", ") }}], union_by_name := true)
SEMI JOIN agent.entries e ON e.path = transcript;
$view$, c::JSON, autoescape := false) AS sql FROM c WHERE len(files) > 0
), posted AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM statements
)
SELECT r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r);
$refresh$ AS sql
), posted AS (
    SELECT sql, array_agg(selfdispatch(sql)) AS receipts
    FROM program GROUP BY sql
)
SELECT cron(sql, '0 */5 * * * *') AS job, r.*
FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

-- Agent transcripts (Claude Code ~/.claude/projects, Codex ~/.codex), read natively, one Parquet per session under
-- ~/.duck/lake/agent at the session's own path.
-- agent.entries: PR #1576's entries shape over fs.files under the transcript roots and the store (fs.sql keeps fs.files
-- current, so a new transcript is listed within a minute). A session is a Claude transcript <project>/<stem>.jsonl plus
-- its <project>/<stem>/subagents/*.jsonl, or one Codex rollout file (.jsonl or .jsonl.zst); its stored copy is
-- <store><session>.parquet. A machine without transcripts lists nothing, copies nothing and never posts agent.lines
-- (read_parquet fails on an empty file list).
-- read_json keeps every top-level field as a column of JSON (maximum_depth 1, map inference off): the same shape in
-- every file. Map inference turns a project's ~170 top-level fields into one MAP; inferred deeper, a field is a STRUCT
-- in one file and a MAP in another, which union_by_name cannot merge. maximum_object_size 32 MB fits the largest line
-- (~21 MB); the reader's buffers are twice it per thread.
-- agent.attachment_fields: every attachment field as a (key, value) row, found with json_keys, so hook runs and other
-- attachments need no hand-typed field list; PIVOT ON key turns one attachment_type back into columns. It is created in
-- the agent.lines rebind below, because it cannot bind before agent.lines exists.
CREATE SCHEMA IF NOT EXISTS agent;
CREATE OR REPLACE VIEW agent.entries AS
WITH roots AS (
    SELECT unnest(['/.claude/projects/', '/.codex/sessions/', '/.codex/archived_sessions/', '/.duck/lake/agent/']) AS root
)
SELECT f.path, parse_dirpath(f.path) AS parent, f.name, f.stem, f.ext, f.bytes, f.modified,
       CASE WHEN f.ext = '.parquet' THEN 'read_parquet' ELSE 'read_json' END AS reader,
       CASE WHEN reader = 'read_parquet' THEN f.path[len(getenv('HOME')) + len(r.root):-9]
            WHEN file_name(parent) = 'subagents' THEN parse_dirpath(parent)
            ELSE f.path[:-(len(f.ext) + 1)] END AS session
FROM fs.files f JOIN roots r ON starts_with(f.path[len(getenv('HOME')) + 1:], r.root)
WHERE f.ext IN ('.jsonl', '.zst', '.parquet');
-- agent.titles: Codex thread names from ~/.codex/session_index.jsonl (id, thread_name, updated_at); id is the session id
-- in the rollout file name. Read through cat so a machine with no Codex index gets an empty view, not a failed boot.
CREATE OR REPLACE VIEW agent.titles AS
SELECT * FROM read_json($cmd$cat "$HOME/.codex/session_index.jsonl" 2>/dev/null; true |$cmd$, format := 'newline_delimited');
-- One refresh program, run once now and every five minutes. Each session with a file newer than its stored copy (or
-- none stored) is copied whole, one post per session, run at the same time: an empty store takes 980 sessions (3.6 GB,
-- ~45 s; failed posts are retried by the next run), a 5-minute run the few active ones (~13 MB, 0.5 s). agent.lines is
-- rebound after the copies with the stored files' literal list, so it never reads a partial file. No changed session
-- means no rows, so nothing is posted.
WITH program AS (
    SELECT $refresh$
WITH c AS (
    SELECT t.session, parse_dirpath(t.session) AS folder, getenv('HOME') AS home, list(quote_literal(t.path)) AS files
    FROM agent.entries t LEFT JOIN agent.entries s ON s.reader = 'read_parquet' AND s.session = t.session
    WHERE t.reader = 'read_json'
    GROUP BY t.session HAVING bool_or(t.modified > coalesce(s.modified, '-infinity'::TIMESTAMP))
), statements AS (
    SELECT tera_render($copy$
SELECT content FROM read_text($cmd$mkdir -p '{{ home }}/.duck/lake/agent{{ folder }}' |$cmd$);
COPY (
    SELECT * FROM read_json([{{ files | join(sep=", ") }}],
        format := 'newline_delimited', maximum_depth := 1, map_inference_threshold := -1, sample_size := -1,
        maximum_object_size := 33554432, ignore_errors := true, union_by_name := true, filename := 'transcript')
) TO '{{ home }}/.duck/lake/agent{{ session }}.parquet' (FORMAT parquet);
$copy$, c::JSON, autoescape := false) AS sql FROM c
), posted AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM statements
)
SELECT r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

WITH c AS (
    SELECT list(quote_literal(path)) AS files FROM agent.entries WHERE reader = 'read_parquet' AND NOT starts_with(name, 'tmp_')
), statements AS (
    SELECT tera_render($view$
-- No join back to agent.entries: the planner put it at ~68M rows and hashed the whole Parquet corpus instead
-- (RIGHT_SEMI build side), 14.9 GiB and an empty stream.blocks at every boot. The literal list already names the files.
CREATE OR REPLACE VIEW agent.lines AS
SELECT * FROM read_parquet([{{ files | join(sep=", ") }}], union_by_name := true, file_row_number := true);
CREATE OR REPLACE VIEW agent.attachment_fields AS
SELECT transcript, file_row_number, (timestamp ->> '$')::TIMESTAMPTZ AS ts, attachment ->> 'type' AS attachment_type,
       key, attachment ->> key AS value
FROM agent.lines CROSS JOIN UNNEST(json_keys(attachment)) AS t(key)
WHERE attachment IS NOT NULL;
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

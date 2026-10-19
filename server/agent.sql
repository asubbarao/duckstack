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
-- agent.messages: one row per message block, agent_data's column names. The full text stays in the next-to-last
-- step: the view returns content_bytes and the first and last 100 characters (head, tail), so a 290 KB paste never
-- fills a reply; a picked row's full text is agent.lines.message where uuid matches. is_prompt is a person's typed
-- message. Columns are read with ->> '$' because agent.lines keeps every top-level field as JSON (see above).
CREATE OR REPLACE VIEW agent.messages AS
WITH line AS (
    SELECT transcript AS file_path, CASE WHEN contains(transcript, '/.codex/') THEN 'codex' ELSE 'claude' END AS source,
           contains(transcript, '/subagents/') AS is_agent, coalesce(sessionId ->> '$', parse_filename(transcript, true)) AS session_id,
           (timestamp ->> '$')::TIMESTAMPTZ AS timestamp, type ->> '$' AS message_type, uuid ->> '$' AS uuid,
           parentUuid ->> '$' AS parent_uuid, cwd ->> '$' AS cwd, gitBranch ->> '$' AS git_branch, entrypoint ->> '$' AS entrypoint,
           CASE WHEN type ->> '$' IN ('user', 'assistant') THEN message
                WHEN payload ->> 'type' IN ('message', 'agent_message', 'function_call', 'custom_tool_call', 'function_call_output') THEN payload END AS msg
    FROM agent.lines
), block AS (
    SELECT * EXCLUDE (msg), coalesce(msg ->> 'role', msg ->> 'type') AS message_role, msg ->> 'model' AS model,
           unnest(CASE json_type(msg -> 'content') WHEN 'ARRAY' THEN json_extract(msg, '$.content[*]') ELSE [coalesce(msg -> 'content', msg)] END) AS b
    FROM line WHERE msg IS NOT NULL
), parsed AS (
    SELECT * EXCLUDE (b), coalesce(b ->> 'type', 'text') AS block_type,
           coalesce(b ->> 'text', b ->> 'thinking', CASE WHEN json_type(b) = 'VARCHAR' THEN b ->> '$' END, b ->> 'output', (b -> 'content')::VARCHAR) AS message_content,
           coalesce(b ->> 'name', b ->> 'call_id') AS tool_name, coalesce(b ->> 'id', b ->> 'tool_use_id', b ->> 'call_id') AS tool_use_id,
           coalesce(b -> 'input', try_cast(b ->> 'arguments' AS JSON)) AS tool_input, strlen(b::VARCHAR) AS content_bytes
    FROM block
), prompts AS (
    SELECT *, message_role = 'user' AND block_type IN ('text', 'input_text') AND NOT is_agent
          AND NOT starts_with(ltrim(message_content), '<') AND NOT starts_with(message_content, '[Request interrupted')
          AND NOT starts_with(message_content, 'This session is being continued')
          AND NOT starts_with(message_content, 'Base directory for this skill')
          AND NOT starts_with(message_content, 'Another Claude session sent a message') AS is_prompt
    FROM parsed
)
SELECT * EXCLUDE (message_content, tool_input), left(message_content, 100) AS head, right(message_content, 100) AS tail,
       left(tool_input::VARCHAR, 100) AS tool_input_head
FROM prompts;

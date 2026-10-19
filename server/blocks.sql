-- Message blocks: one row per block of every Claude and Codex message, agent_data's column names. Columns are read with
-- ->> '$' because agent.lines keeps every top-level field as JSON (agent.sql). block_key is file:line:block (line is the
-- record's row in its stored file), unique by construction. A resumed session repeats lines under the same uuid in its
-- own file; they stay rows, deduped by uuid in the query. is_prompt is a person's typed message.
-- stream.parsed: the parse of agent.lines, the build's input only; it reads every stored file, so nothing queries it.
-- A view in the stream catalog resolves names inside stream, so it names dev.agent.lines.
-- stream.blocks: the one table, in an in-memory database with a BM25 index on message_content. Built whole at boot;
-- every 15 minutes, 30 s after the copies, it keeps its rows older than 20 minutes, re-reads the last 20 from
-- stream.parsed, then rebuilds the index (fts has no incremental update). In memory, so nothing writes a WAL. fts
-- names its tables without a catalog, so a search sets search_path = 'dev.main,stream.main' first.
-- agent.messages: stream.blocks without the full text (head, tail), so a 290 KB paste never fills a reply.
-- agent.sessions: one row per session to pick from, then read its blocks by session_id: activity, and the count and
-- first and last of its prompts after near-repeats are dropped (rapidfuzz_ratio 90+ against the previous prompt).
-- The build runs as cron jobs, never posted: a post through quack_query binds every statement before the first runs,
-- and each statement here needs the one before it (cron runs them in order). The index is its own job a minute later:
-- DuckDB expands a PRAGMA when the batch is parsed, before the table above it exists. Meanwhile the old index still
-- serves, keyed on block_key. first_build and first_index run 15 s and 75 s after boot (cron schedules are UTC); their
-- schedules next match a year on, past any restart. A machine with no agent.lines gets a failed job, not a failed boot.
ATTACH IF NOT EXISTS ':memory:' AS stream;
WITH program AS (
    SELECT $build$
CREATE OR REPLACE VIEW stream.main.parsed AS
WITH line AS (
    SELECT ['text', 'thinking', 'output', 'content'] AS content_keys, ['name', 'call_id'] AS name_keys,
           ['id', 'tool_use_id', 'call_id'] AS id_keys,
           ['<', '[Request interrupted', 'This session is being continued', 'Base directory for this skill',
            'Another Claude session sent a message'] AS harness_prefixes,
           transcript AS file_path, file_row_number AS line, CASE WHEN contains(transcript, '/.codex/') THEN 'codex' ELSE 'claude' END AS source,
           contains(transcript, '/subagents/') AS is_agent, coalesce(sessionId ->> '$', parse_filename(transcript, true)) AS session_id,
           (timestamp ->> '$')::TIMESTAMPTZ AS timestamp, type ->> '$' AS message_type, uuid ->> '$' AS uuid,
           parentUuid ->> '$' AS parent_uuid, cwd ->> '$' AS cwd, gitBranch ->> '$' AS git_branch, entrypoint ->> '$' AS entrypoint,
           CASE WHEN type ->> '$' IN ('user', 'assistant') THEN message
                WHEN payload ->> 'type' IN ('message', 'agent_message', 'function_call', 'custom_tool_call', 'function_call_output') THEN payload END AS msg
    FROM dev.agent.lines
), block AS (
    SELECT l.* EXCLUDE (msg), coalesce(msg ->> 'role', msg ->> 'type') AS message_role, msg ->> 'model' AS model,
           t.b, t.block_index, concat_ws(':', file_path, line, t.block_index) AS block_key
    FROM line l
    CROSS JOIN UNNEST(CASE json_type(msg -> 'content') WHEN 'ARRAY' THEN (msg -> 'content')::JSON[] ELSE [coalesce(msg -> 'content', msg)] END)
        WITH ORDINALITY AS t(b, block_index)
    WHERE msg IS NOT NULL
), parsed AS (
    SELECT * EXCLUDE (b, content_keys, name_keys, id_keys), coalesce(b ->> 'type', 'text') AS block_type,
           coalesce(CASE WHEN json_type(b) = 'VARCHAR' THEN b ->> '$' END,
                    list_filter(list_transform(content_keys, lambda k: b ->> k), lambda v: v IS NOT NULL)[1]) AS message_content,
           list_filter(list_transform(name_keys, lambda k: b ->> k), lambda v: v IS NOT NULL)[1] AS tool_name,
           list_filter(list_transform(id_keys, lambda k: b ->> k), lambda v: v IS NOT NULL)[1] AS tool_use_id,
           coalesce(b -> 'input', try_cast(b ->> 'arguments' AS JSON)) AS tool_input, strlen(b::VARCHAR) AS content_bytes
    FROM block
)
SELECT * EXCLUDE (harness_prefixes),
       message_role = 'user' AND block_type IN ('text', 'input_text') AND NOT is_agent
       AND NOT list_bool_or(list_transform(harness_prefixes, lambda p: starts_with(ltrim(message_content), p))) AS is_prompt
FROM parsed;
CREATE TABLE IF NOT EXISTS stream.main.blocks AS SELECT * FROM stream.main.parsed;
CREATE OR REPLACE TABLE stream.main.blocks AS
SELECT * FROM stream.main.blocks WHERE (timestamp >= now() - INTERVAL 20 MINUTE) IS NOT TRUE
UNION ALL BY NAME
SELECT * FROM stream.main.parsed WHERE timestamp >= now() - INTERVAL 20 MINUTE;
CREATE OR REPLACE VIEW dev.agent.messages AS
SELECT * EXCLUDE (message_content, tool_input), left(message_content, 100) AS head,
       right(message_content, 100) AS tail, left(tool_input::VARCHAR, 100) AS tool_input_head
FROM stream.blocks;
CREATE OR REPLACE VIEW dev.agent.sessions AS
WITH prompt AS (
    SELECT session_id, timestamp, left(message_content, 200) AS opening,
           lag(opening) OVER (PARTITION BY session_id ORDER BY timestamp) AS previous_opening
    FROM stream.blocks WHERE is_prompt
), prompts AS (
    SELECT session_id, count(opening) AS prompts, arg_min(opening, timestamp) AS first_prompt, arg_max(opening, timestamp) AS last_prompt
    FROM prompt WHERE (rapidfuzz_ratio(opening, previous_opening) >= 90) IS NOT TRUE
    GROUP BY session_id
), activity AS (
    SELECT session_id, source, min(timestamp) AS started, max(timestamp) AS last_active, count(block_key) AS blocks
    FROM stream.blocks GROUP BY session_id, source
)
SELECT a.*, p.prompts, p.first_prompt, p.last_prompt
FROM activity a LEFT JOIN prompts p USING (session_id);
$build$ AS build,
           $index$PRAGMA create_fts_index('stream.main.blocks', 'block_key', 'message_content', overwrite = 1)$index$ AS rebuild_index,
           timezone('UTC', now()) AS booted
)
SELECT cron(build, '30 */15 * * * *') AS build_job,
       cron(rebuild_index, '30 1-59/15 * * * *') AS index_job,
       cron(build, strftime(booted + INTERVAL 15 SECOND, '%S %M %H %d %m *')) AS first_build,
       cron(rebuild_index, strftime(booted + INTERVAL 75 SECOND, '%S %M %H %d %m *')) AS first_index
FROM program;

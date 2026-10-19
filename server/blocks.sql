-- Message blocks: one row per block of every Claude and Codex message, agent_data's column names. Columns are read with
-- ->> '$' because agent.lines keeps every top-level field as JSON (agent.sql). block_key is file:line:block (line is the
-- record's row in its stored file), unique by construction. is_repeat marks a resumed session's copy of a line (same uuid,
-- not the file where it first appeared). is_prompt is a person's typed message.
-- stream.parsed: the parse of agent.lines, the build's input only; it reads every stored file, so nothing queries it.
-- A view in the stream catalog resolves names inside stream, so it names dev.agent.lines.
-- stream.blocks: the one table, in an in-memory database (nothing writes a WAL) with a BM25 index on message_content.
-- The refresh posts one statement per step, each built from the previous step's receipt: a post binds alone, so a step
-- may use what the one before it created, and the PRAGMA (expanded when parsed) runs after the table exists. Posted now
-- and every 15 minutes, 30 s after the copies: the table keeps its rows older than 20 minutes and re-reads the last 20.
-- fts names its tables without a catalog, so a search sets search_path = 'dev.main,stream.main' first.
ATTACH IF NOT EXISTS ':memory:' AS stream;
WITH program AS (
    SELECT $refresh$
WITH intent AS (
    SELECT $v$
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
       uuid IS NOT NULL AND file_path IS DISTINCT FROM arg_min(file_path, timestamp) OVER (PARTITION BY uuid) AS is_repeat,
       message_role = 'user' AND block_type IN ('text', 'input_text') AND NOT is_agent
       AND NOT list_bool_or(list_transform(harness_prefixes, lambda p: starts_with(ltrim(message_content), p))) AS is_prompt
FROM parsed
$v$ AS parsed_sql,
           $c$CREATE TABLE IF NOT EXISTS stream.main.blocks AS SELECT * FROM stream.main.parsed$c$ AS create_sql,
           $w$
CREATE OR REPLACE TABLE stream.main.blocks AS
SELECT * FROM stream.main.blocks WHERE (timestamp >= now() - INTERVAL 20 MINUTE) IS NOT TRUE
UNION ALL BY NAME
SELECT * FROM stream.main.parsed WHERE timestamp >= now() - INTERVAL 20 MINUTE
$w$ AS window_sql,
           $p$PRAGMA create_fts_index('stream.main.blocks', 'block_key', 'message_content', overwrite = 1)$p$ AS index_sql
), parsed_step AS (
    SELECT create_sql, window_sql, index_sql, array_agg(selfdispatch(parsed_sql)) AS receipts
    FROM intent GROUP BY create_sql, window_sql, index_sql
), create_step AS (
    SELECT window_sql, index_sql, array_agg(selfdispatch(create_sql)) AS receipts
    FROM parsed_step CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200 GROUP BY window_sql, index_sql
), window_step AS (
    SELECT index_sql, array_agg(selfdispatch(window_sql)) AS receipts
    FROM create_step CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200 GROUP BY index_sql
), index_step AS (
    SELECT array_agg(selfdispatch(index_sql)) AS receipts
    FROM window_step CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200 GROUP BY index_sql
)
SELECT r.* FROM index_step CROSS JOIN UNNEST(receipts) AS t(r);
$refresh$ AS sql
), posted AS (
    SELECT sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY sql
)
SELECT cron(sql, '30 */15 * * * *') AS job, r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

-- The views over the table, once, after the boot build above.
-- agent.messages: stream.blocks without the full text (head, tail), so a 290 KB paste never fills a reply.
-- agent.sessions: one row per session to pick from, then read its blocks by session_id: activity, and the count and
-- first and last of its prompts, near-repeats dropped (rapidfuzz_ratio 90+ against the previous prompt).
WITH intent AS (
    SELECT unnest([$m$
CREATE OR REPLACE VIEW agent.messages AS
SELECT * EXCLUDE (message_content, tool_input), left(message_content, 100) AS head,
       right(message_content, 100) AS tail, left(tool_input::VARCHAR, 100) AS tool_input_head
FROM stream.blocks
$m$, $s$
CREATE OR REPLACE VIEW agent.sessions AS
WITH prompt AS (
    SELECT session_id, timestamp, left(message_content, 200) AS opening,
           lag(opening) OVER (PARTITION BY session_id ORDER BY timestamp) AS previous_opening
    FROM stream.blocks WHERE is_prompt AND NOT is_repeat
), prompts AS (
    SELECT session_id, count(opening) AS prompts, arg_min(opening, timestamp) AS first_prompt, arg_max(opening, timestamp) AS last_prompt
    FROM prompt WHERE (rapidfuzz_ratio(opening, previous_opening) >= 90) IS NOT TRUE
    GROUP BY session_id
), activity AS (
    SELECT session_id, source, min(timestamp) AS started, max(timestamp) AS last_active, count(block_key) AS blocks
    FROM stream.blocks WHERE NOT is_repeat GROUP BY session_id, source
)
SELECT a.*, p.prompts, p.first_prompt, p.last_prompt
FROM activity a LEFT JOIN prompts p USING (session_id)
$s$]) AS sql
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM intent
)
SELECT r.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(r);

-- stream.blocks: one row per block of every Claude and Codex message, agent_data's column names, in an in-memory
-- database (nothing writes a WAL) with a BM25 index on message_content. block_key is file:line:block (line is the
-- record's row in its stored file), unique by construction. is_prompt is a person's typed message.
-- stream.parsed: the parse of agent.lines (fields are JSON there, hence ->> '$'); the build's input only. A view in the
-- stream catalog resolves names inside stream, so it names dev.agent.lines.
-- Boot builds the view, the table and the index, each its own post built from the previous step's receipt (a post binds
-- alone; the PRAGMA is expanded when parsed), and returns every receipt. blocks_refresh.sql keeps it current.
-- fts names its tables without a catalog, so a search sets search_path = 'dev.main,stream.main' first.
ATTACH IF NOT EXISTS ':memory:' AS stream;
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
           coalesce(CASE WHEN json_type(b) = 'VARCHAR' THEN b ->> '$' END, [b ->> k FOR k IN content_keys IF b ->> k IS NOT NULL][1]) AS message_content,
           [b ->> k FOR k IN name_keys IF b ->> k IS NOT NULL][1] AS tool_name,
           [b ->> k FOR k IN id_keys IF b ->> k IS NOT NULL][1] AS tool_use_id,
           coalesce(b -> 'input', try_cast(b ->> 'arguments' AS JSON)) AS tool_input, strlen(b::VARCHAR) AS content_bytes
    FROM block
)
SELECT * EXCLUDE (harness_prefixes),
       message_role = 'user' AND block_type IN ('text', 'input_text') AND NOT is_agent
       AND NOT list_bool_or([starts_with(ltrim(message_content), p) FOR p IN harness_prefixes]) AS is_prompt
FROM parsed
$v$ AS parsed_sql,
           $c$CREATE TABLE IF NOT EXISTS stream.main.blocks AS SELECT * FROM stream.main.parsed$c$ AS create_sql,
           $p$PRAGMA create_fts_index('stream.main.blocks', 'block_key', 'message_content', overwrite = 1)$p$ AS index_sql
), parsed_step AS (
    SELECT create_sql, index_sql, array_agg(selfdispatch(parsed_sql)) AS receipts FROM intent GROUP BY create_sql, index_sql
), create_step AS (
    SELECT index_sql, array_agg(selfdispatch(create_sql)) AS receipts
    FROM parsed_step CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200 GROUP BY index_sql
), index_step AS (
    SELECT array_agg(selfdispatch(index_sql)) AS receipts
    FROM create_step CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200 GROUP BY index_sql
)
SELECT r.* FROM parsed_step CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL SELECT r.* FROM create_step CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL SELECT r.* FROM index_step CROSS JOIN UNNEST(receipts) AS t(r);

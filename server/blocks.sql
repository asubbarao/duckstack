-- stream.blocks: one row per block of every Claude and Codex message, agent_data's column names, in an in-memory
-- database (nothing writes a WAL) with a BM25 index on message_content. block_key is file:line:block (line is the
-- record's row in its stored file), unique by construction. is_prompt is a person's typed message. is_repeat marks a
-- resumed session's copy of a line: same uuid, not the earliest (timestamp, file, line) holding it; computed at each build.
-- The line matters because Claude Desktop re-appends its history into the same file after each bridge-session line.
-- tool_part is 'call' or 'result' for a tool call's two blocks, NULL for a message; a call's message_content is its command.
-- stream.parsed: the parse of agent.lines (fields are JSON there, hence ->> '$'); the build's input only. A view in the
-- stream catalog resolves names inside stream, so it names dev.agent.lines.
-- Boot posts the view, then the empty table from that receipt (a post binds alone), and returns every receipt.
-- blocks_refresh.sql fills it (at boot every transcript is new to it) and builds the index.
ATTACH IF NOT EXISTS ':memory:' AS stream;
WITH intent AS (
    SELECT $v$
CREATE OR REPLACE VIEW stream.main.parsed AS
-- Codex writes its session id, cwd and branch once, in session_meta; the file's own is its first (later ones are copied
-- parents). A window by transcript, not a join, so the refresh's file_path filter still reaches the Parquet scan.
WITH line AS (
    SELECT ['text', 'thinking', 'output', 'content'] AS content_keys,
           ['call_id', 'tool_use_id', 'id'] AS id_keys, ['command', 'cmd', 'sql', '$'] AS command_keys,
           ['content', 'output'] AS part_keys, ['message', 'agent_message'] AS message_types,
           ['tool_use', 'function_call', 'custom_tool_call'] AS call_types,
           ['tool_result', 'function_call_output', 'custom_tool_call_output'] AS result_types,
           ['<', '[Request interrupted', 'This session is being continued', 'Base directory for this skill',
            'Another Claude session sent a message', '# AGENTS.md', '[Cross-session delivery notice]',
            'Here is a note offered by a side agent'] AS harness_prefixes,
           arg_min(payload, CASE WHEN type ->> '$' = 'session_meta' THEN file_row_number END) OVER (PARTITION BY transcript) AS codex_meta,
           transcript AS file_path, file_row_number AS line, CASE WHEN contains(transcript, '/.codex/') THEN 'codex' ELSE 'claude' END AS source,
           contains(transcript, '/subagents/') AS is_agent,
           coalesce(sessionId ->> '$', codex_meta ->> 'id', parse_filename(transcript, true)) AS session_id,
           (timestamp ->> '$')::TIMESTAMPTZ AS timestamp, type ->> '$' AS message_type, uuid ->> '$' AS uuid,
           parentUuid ->> '$' AS parent_uuid, coalesce(cwd ->> '$', codex_meta ->> 'cwd') AS cwd,
           coalesce(gitBranch ->> '$', codex_meta ->> '$.git.branch') AS git_branch, entrypoint ->> '$' AS entrypoint,
           CASE WHEN type ->> '$' IN ('user', 'assistant') THEN message
                WHEN list_contains(message_types || call_types || result_types, payload ->> 'type') THEN payload END AS msg
    FROM dev.agent.lines
), block AS (
    SELECT l.* EXCLUDE (msg, codex_meta), coalesce(msg ->> 'role', msg ->> 'type') AS message_role, msg ->> 'model' AS model,
           t.b, t.block_index, concat_ws(':', file_path, line, t.block_index) AS block_key
    FROM line l
    CROSS JOIN UNNEST(CASE json_type(msg -> 'content') WHEN 'ARRAY' THEN (msg -> 'content')::JSON[] ELSE [coalesce(msg -> 'content', msg)] END)
        WITH ORDINALITY AS t(b, block_index)
    WHERE msg IS NOT NULL
), parsed AS (
    SELECT * EXCLUDE (b, content_keys, id_keys, part_keys, message_types), coalesce(b ->> 'type', 'text') AS block_type,
           CASE WHEN list_contains(call_types, block_type) THEN 'call' WHEN list_contains(result_types, block_type) THEN 'result' END AS tool_part,
           -- a tool result's content (Claude) or output (Codex) can be a list of {type, text} parts, joined by
           -- newlines (Tera reads "\n" as one: on dev, 1554 multi-part results equal their newline join).
           -- NUL bytes are dropped first: a transcript holds one when an agent read a binary file as text, and a
           -- NUL inside a tera value aborts the whole server (14 boot crashes on 2026-10-21).
           [b -> k FOR k IN part_keys IF json_type(b -> k) = 'ARRAY'][1] AS part_array,
           [replace(p ->> 'text', chr(0), '') FOR p IN CAST(part_array AS JSON[]) IF p ->> 'text' IS NOT NULL] AS text_parts,
           coalesce(CASE WHEN len(text_parts) > 0 THEN tera_render('{{ parts | join(sep="\n") }}', {'parts': text_parts}::JSON, autoescape := false) END,
                    CASE WHEN json_type(b) = 'VARCHAR' THEN b ->> '$' END, [b ->> k FOR k IN content_keys IF b ->> k IS NOT NULL][1]) AS message_content,
           b ->> 'name' AS tool_name,
           -- call_id first: a Codex call and its output share call_id, and each also has its own item id
           [b ->> k FOR k IN id_keys IF b ->> k IS NOT NULL][1] AS tool_use_id,
           (b ->> 'is_error')::BOOLEAN AS is_error,
           coalesce(b -> 'input', try_cast(b ->> 'arguments' AS JSON)) AS tool_input, strlen(b::VARCHAR) AS content_bytes,
           [tool_input ->> k FOR k IN command_keys IF tool_input ->> k IS NOT NULL][1] AS tool_command
    FROM block
)
-- a tool call's text is its command, so the BM25 index on message_content finds the SQL and commands agents ran
SELECT * EXCLUDE (harness_prefixes, command_keys, call_types, result_types, part_array, text_parts)
         REPLACE (coalesce(message_content, tool_command) AS message_content),
       message_role = 'user' AND block_type IN ('text', 'input_text') AND NOT is_agent
       AND NOT list_bool_or([starts_with(ltrim(message_content), p) FOR p IN harness_prefixes]) AS is_prompt
FROM parsed
$v$ AS parsed_sql
), parsed_step AS (
    SELECT array_agg(selfdispatch(parsed_sql)) AS receipts FROM intent
), create_step AS (
    SELECT array_agg(selfdispatch($c$CREATE TABLE IF NOT EXISTS stream.main.blocks AS SELECT *, false AS is_repeat FROM stream.main.parsed LIMIT 0$c$)) AS receipts
    FROM parsed_step CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200
)
SELECT r.* FROM parsed_step CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL SELECT r.* FROM create_step CROSS JOIN UNNEST(receipts) AS t(r);

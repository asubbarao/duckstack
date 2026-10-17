-- Agent transcripts (Claude Code ~/.claude/projects, Codex ~/.codex/sessions and archived_sessions) as one table,
-- agent.stream, kept current by one refresh program that runs at boot and every minute.
CREATE SCHEMA IF NOT EXISTS agent;
-- agent.titles: Codex thread names from ~/.codex/session_index.jsonl; id is the session id in the rollout file name.
CREATE OR REPLACE VIEW agent.titles AS
SELECT id, thread_name AS title, updated_at::TIMESTAMPTZ AS updated_at FROM read_json(getenv('HOME') || '/.codex/session_index.jsonl', format := 'newline_delimited');

-- agent.stream: one row per event, appended and never rewritten. A transcript line is one event, or one per content
-- block when it holds several (`part` counts them from 1); line (the raw JSON) and fields (every path in it, unpivoted,
-- with its type) are on part 1. Everything is parsed once, when the line is appended: the event columns below, and
-- for a tool call what its shell or SQL input runs.
--   session_id / parent_session_id  Claude: the transcript file's name (a subagent's is agent-<id>) and, for a
--            subagent, its session's; Codex: the thread id and, for a subagent thread, its parent thread's
--   line_number, byte_offset, bytes  where the line is in its transcript file; the refresh reads from the line after
--            the last stored one (byte_offset + bytes of a compressed .jsonl.zst rollout count its decompressed bytes)
--   ts       the line's time (`at` does not parse as a column name in DuckDB 1.5); NULL on lines that carry none
--   speaker  user | assistant | system | tool (a tool's result is the tool speaking)
--   kind     message | thinking | tool_call | tool_result | image | summary | title | context (text the harness
--            added to the model's input) | notice (harness status and errors) | state (bookkeeping lines)
--   content  the text; for a tool call its command, SQL or code, else its arguments as JSON; for a result its output
--   content_format  shell | sql | javascript | patch | json | text: how to read content
--   entry_type  the transcript's own names for what produced the event (line type / block or payload type)
--   programs, shell_parses  shell input: the program each command runs, in order, and whether the bash parse is clean
--   sql_parses, statement_kinds, tables, functions  SQL input: DuckDB's parser accepts it; each statement's kind;
--            tables read and written; functions called (parser_tools plus sitting_duck, which also sees table functions)
--   item_id, is_nested_run  Codex: an item_completed line for a tool the exec script ran is two events (its call and
--            result) unless item_id is a call the thread already made, which agent.events leaves out as a repeat
--
-- One statement, in stages, each built from the one before:
--   template     the append: one transcript's new lines in, typed event rows out ({{ name }} is a value filled per row)
--   created      the table, if it does not exist yet: the append over no lines (parse_lines of an empty string), so
--                its columns are the append's
--   program      the refresh, with the append written into it
--   views        agent.events, agent.tool_calls and agent.keys over the table
--   posted       the refresh, run now (on an empty table, the initial fill) and every minute by cron
-- The refresh, in its own stages:
--   transcripts  every transcript file on this machine, and its size (a root that does not exist lists nothing)
--   stored       per transcript, the last stored line, the byte where it ends, and what later lines need from earlier
--                ones (Codex's thread ids and the model of the current turn)
--   work         a transcript whose file has grown past its last stored line, or a .zst rollout not read to its end, and
--                how many bytes it has not stored
--   queued       this run's share, smallest first, until 64 MB are queued (always at least one): an append holds
--                ~85 times the bytes it reads at its peak, so a run stays near 5 GB and an empty table fills over a
--                run a minute
--   statements   one append per transcript: its new lines, read from the one file by literal path, at most 2,000
--                lines a post (a longer file continues on the next run)
--   posted       the appends go out together and come back as receipts; no work means nothing is posted
-- A line still being written (no newline yet) is not read; the next run starts at it.
WITH template AS (
    SELECT $append$
{{ into }}
WITH raw AS (
    SELECT line_number, byte_offset, strlen(content) AS bytes, TRY_CAST(content AS JSON) AS line
    FROM {{ reader }}({{ source }}, lines := {{ lines }})
    WHERE ends_with(content, e'\n')
), fields AS (
    -- every path in the line, unpivoted: json_structure folds an array's elements into one shape ([0]) and json_tree
    -- gives one row per path of that shape, with its JSON type
    SELECT line_number, list({'path': s.fullkey, 'type': CASE WHEN s.type IN ('OBJECT', 'ARRAY') THEN s.type ELSE s.value ->> '$' END} ORDER BY s.id) AS fields
    FROM raw CROSS JOIN LATERAL json_tree(json_structure(raw.line)) AS s
    WHERE s.parent IS NOT NULL
    GROUP BY line_number
), lines AS (
    -- each line is parsed once: its top-level fields come back as one list, named here
    SELECT line_number, byte_offset, bytes, line,
           f[1] ->> '$' AS line_type, TRY_CAST(f[2] ->> '$' AS TIMESTAMPTZ) AS ts, f[3] AS message, f[4] AS payload,
           f[5] AS attachment, f[6] AS subtype, f[7] AS isMeta, f[8] AS origin, f[9] AS isCompactSummary,
           f[10] AS isApiErrorMessage, f[11] AS rendered, f[12] AS level, f[13] AS error, f[14] AS aiTitle,
           f[15] AS customTitle, f[16] AS line_content
    FROM (SELECT *, line -> ['type', 'timestamp', 'message', 'payload', 'attachment', 'subtype', 'isMeta', 'origin',
                             'isCompactSummary', 'isApiErrorMessage', 'rendered', 'level', 'error', 'aiTitle',
                             'customTitle', 'content'] AS f
          FROM raw)
),

-- Claude Code: <project>/<session>.jsonl, and <project>/<session>/subagents/agent-<id>.jsonl for its subagents.
-- A user or assistant line's message.content is a string or an array of blocks; each block is an event (a string is
-- one text block). Every other line (system, attachment, titles, bookkeeping) is one event.
claude_lines AS (
    SELECT * EXCLUDE (payload, message), message -> ['content', 'model'] AS m,
           CASE WHEN line_type NOT IN ('user', 'assistant') THEN [NULL::JSON]
                WHEN json_type(m[1]) <> 'ARRAY' THEN [json_object('type', 'text', 'text', m[1] ->> '$')]
                WHEN json_array_length(m[1]) = 0 THEN [NULL::JSON]
                ELSE m[1]::JSON[] END AS blocks
    FROM lines WHERE {{ agent }} = 'claude'
), claude_parts AS (
    -- unnest in the select list streams; a lateral UNNEST joins back on every column it reads
    SELECT * EXCLUDE (blocks), unnest(coalesce(blocks, [NULL::JSON])) AS block,
           generate_subscripts(coalesce(blocks, [NULL::JSON]), 1) AS part
    FROM claude_lines
), claude_fields AS (
    SELECT * EXCLUDE (m, block, b, bj, a),
           m[2] ->> '$' AS model, b[1] AS block_type, b[2] AS block_text, b[3] AS thinking, b[4] AS name,
           coalesce(b[5], b[6]) AS block_call_id, b[7]::BOOLEAN AS block_is_error, b[8] AS media_type,
           bj[1] AS input, bj[2] AS result,
           a[1] AS attachment_type, a[2] AS attachment_call_id, coalesce(a[3], a[4], a[5], a[6]) AS attachment_text
    FROM (SELECT *, block ->> ['type', 'text', 'thinking', 'name', 'id', 'tool_use_id', 'is_error', '$.source.media_type'] AS b,
                 block -> ['input', 'content'] AS bj,
                 attachment ->> ['type', 'toolUseID', 'content', 'text', 'prompt', 'stderr'] AS a
          FROM claude_parts)
), claude_events AS (
    SELECT 'claude' AS source, {{ session_id }} AS session_id, nullif({{ parent_session_id }}, '') AS parent_session_id,
           {{ is_subagent }} AS is_subagent, NULL::VARCHAR AS agent_path,
           line_number, part, byte_offset, bytes, ts, model, line_type, line,
           CASE line_type WHEN 'attachment' THEN 'attachment/' || attachment_type
                          WHEN 'system' THEN 'system/' || (subtype ->> '$')
                          WHEN 'user' THEN 'user/' || block_type
                          WHEN 'assistant' THEN 'assistant/' || block_type
                          ELSE line_type END AS entry_type,
           CASE WHEN line_type = 'assistant' THEN 'assistant'
                WHEN line_type <> 'user' THEN 'system'
                WHEN block_type = 'tool_result' THEN 'tool'
                -- skill bodies, caveats, task notifications, compaction summaries: user turns Claude Code wrote
                WHEN (isMeta ->> '$')::BOOLEAN THEN 'system'
                WHEN (isCompactSummary ->> '$')::BOOLEAN THEN 'system'
                WHEN coalesce(origin ->> 'kind', 'human') <> 'human' THEN 'system'
                ELSE 'user' END AS speaker,
           CASE WHEN line_type = 'attachment' THEN 'context'
                WHEN line_type IN ('ai-title', 'custom-title') THEN 'title'
                WHEN (subtype ->> '$') = 'away_summary' THEN 'summary'
                WHEN line_type = 'system' THEN 'notice'
                WHEN line_type NOT IN ('user', 'assistant') THEN 'state'
                WHEN (isCompactSummary ->> '$')::BOOLEAN THEN 'summary'
                WHEN block_type = 'text' THEN 'message'
                WHEN block_type IN ('thinking', 'redacted_thinking') THEN 'thinking'
                WHEN block_type = 'tool_use' THEN 'tool_call'
                ELSE block_type END AS kind,
           CASE WHEN block_type = 'tool_use' THEN name END AS tool_name,
           -- a hook's output names the tool call it ran for
           coalesce(block_call_id, attachment_call_id) AS tool_call_id,
           -- a tool's input: its command, SQL or code when it has one
           input ->> ['command', 'sql', 'statement', 'code'] AS i,
           CASE WHEN line_type IN ('user', 'assistant') THEN CASE block_type
                    WHEN 'text' THEN block_text
                    WHEN 'thinking' THEN thinking
                    WHEN 'tool_use' THEN coalesce(i[1], i[2], i[3], i[4], input::VARCHAR)
                    -- a result is a string or blocks: text, images, and tool names for ToolSearch
                    WHEN 'tool_result' THEN CASE json_type(result)
                        WHEN 'ARRAY' THEN coalesce(list_aggregate(result ->> '$[*].text', 'string_agg', e'\n'),
                                                   list_aggregate(result ->> '$[*].tool_name', 'string_agg', e'\n'))
                        ELSE result ->> '$' END
                    WHEN 'image' THEN media_type END
                -- what the model was shown, else the attachment's own text (hook output, queued prompt)
                WHEN line_type = 'attachment' THEN coalesce(list_aggregate(rendered ->> '$[*].content', 'string_agg', e'\n'), attachment_text)
                WHEN line_type = 'system' THEN coalesce(line_content ->> '$', error::VARCHAR)
                WHEN line_type = 'ai-title' THEN aiTitle ->> '$'
                WHEN line_type = 'custom-title' THEN customTitle ->> '$'
                WHEN line_type = 'queue-operation' THEN line_content ->> '$'
                END AS content,
           CASE WHEN block_type <> 'tool_use' THEN 'text'
                WHEN i[1] IS NOT NULL THEN 'shell'
                WHEN coalesce(i[2], i[3]) IS NOT NULL THEN 'sql'
                WHEN i[4] IS NOT NULL THEN 'javascript'
                WHEN block_type = 'tool_use' THEN 'json'
                ELSE 'text' END AS content_format,
           CASE WHEN block_is_error THEN true
                WHEN (isApiErrorMessage ->> '$')::BOOLEAN THEN true
                WHEN (level ->> '$') = 'error' THEN true
                WHEN attachment_type IN ('hook_non_blocking_error', 'hook_cancelled') THEN true
                ELSE false END AS is_error,
           NULL::VARCHAR AS item_id, false AS is_nested_run
    FROM claude_fields
),

-- Codex: one rollout file per thread. Its first session_meta line names the thread and, for a subagent, its parent
-- (a forked rollout then repeats its parent's session_meta); turn_context lines name each turn's model. A later
-- append starts with what the stored lines said (the session, model and agent_path values rendered below).
codex_payloads AS (
    -- payload: the line's own fields, and for an item_completed line the item's (a tool the exec script ran)
    SELECT line_number, byte_offset, bytes, ts, line_type, line,
           payload ->> ['type', 'call_id', 'name', 'namespace', 'role', 'author', 'input', 'arguments', 'output',
                        '$.internal_chat_message_metadata_passthrough.turn_id', 'turn_id', 'model', 'reason', 'message',
                        'started_at_ms', 'completed_at_ms', 'id', 'parent_thread_id', 'agent_path',
                        '$.item.type', '$.item.id', '$.item.status', '$.item.exit_code', '$.item.server', '$.item.tool',
                        '$.item.namespace', '$.item.kind', '$.item.query', '$.item.path', '$.item.aggregated_output',
                        '$.item.stdout', '$.item.stderr', '$.item.error', '$.item.success', '$.item.command[2]',
                        '$.item.result.isError'] AS f,
           payload -> ['content', 'output', 'summary', '$.item.arguments', '$.item.result.content', '$.item.changes',
                       '$.item.results', '$.item.content_items', '$.item.action', '$.item.receiver_thread_ids'] AS j
    FROM lines WHERE {{ agent }} = 'codex'
), codex AS (
    SELECT line_number, byte_offset, bytes, ts, line_type, line,
           f[1] AS payload_type, f[2] AS call_id, f[3] AS name, f[4] AS namespace, f[5] AS role, f[6] AS author,
           f[7] AS input, f[8] AS arguments, f[9] AS output_text, f[13] AS reason, f[14] AS summary_text,
           f[15]::BIGINT AS started_ms, f[16]::BIGINT AS completed_ms,
           f[20] AS item_type, f[21] AS item_id, f[22] AS item_status, f[23]::BIGINT AS exit_code, f[24] AS server,
           f[25] AS tool, f[26] AS item_namespace, f[27] AS item_kind, f[28] AS query, f[29] AS path,
           f[30] AS aggregated_output, f[31] AS stdout, f[32] AS stderr, f[33] AS item_error, f[34]::BOOLEAN AS success,
           -- a command is [shell, '-lc', script]
           f[35] AS script, f[36]::BOOLEAN AS result_is_error,
           j[1] AS content_parts, j[2] AS output, j[3] AS summary_parts, j[4] AS item_arguments, j[5] AS result_content,
           j[6] AS changes, j[7] AS results, j[8] AS content_items, j[9] AS action, j[10] AS receivers,
           -- the thread: from the first session_meta line in these lines
           first_value(CASE WHEN line_type = 'session_meta' THEN {'id': f[17], 'parent': f[18], 'agent_path': f[19]} END IGNORE NULLS)
               OVER (ORDER BY line_number ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS thread,
           -- the model: the latest turn_context at or before the line
           last_value(CASE WHEN line_type = 'turn_context' THEN f[12] END IGNORE NULLS)
               OVER (ORDER BY line_number ROWS UNBOUNDED PRECEDING) AS turn_model
    FROM codex_payloads
), codex_lines AS (
    SELECT *,
           -- a session already stored keeps its ids; the first append takes them from its session_meta line
           coalesce(nullif({{ session_id }}, ''), thread.id) AS session_id,
           CASE WHEN nullif({{ session_id }}, '') IS NULL THEN thread.parent ELSE nullif({{ parent_session_id }}, '') END AS parent_session_id,
           parent_session_id IS NOT NULL AS is_subagent,
           coalesce(nullif({{ agent_path }}, ''), thread.agent_path, '/root') AS agent_path,
           coalesce(turn_model, nullif({{ model }}, '')) AS model,
           -- an item_completed line for a tool the exec script ran itself (a shell command, an MCP tool, a patch)
           coalesce(item_type IN ('CommandExecution', 'McpToolCall', 'FileChange', 'Extension', 'ImageView',
                                  'DynamicToolCall', 'CollabAgentToolCall'), false) AS is_nested_run,
           -- events per line: a message's content parts, a nested run's call and result, else the line itself
           CASE WHEN payload_type = 'message' AND json_array_length(content_parts) > 0 THEN content_parts::JSON[]
                WHEN is_nested_run THEN [NULL::JSON, NULL::JSON]
                ELSE [NULL::JSON] END AS blocks
    FROM codex
), codex_parts AS (
    SELECT * EXCLUDE (blocks), unnest(blocks) AS block, generate_subscripts(blocks, 1) AS part FROM codex_lines
), codex_fields AS (
    SELECT *,
           -- what the event is: a response_item (the model's input and output), a nested run's call or result, or a
           -- line of bookkeeping
           CASE WHEN line_type = 'response_item' THEN payload_type
                WHEN NOT is_nested_run THEN 'line'
                WHEN part = 1 THEN 'run_call'
                ELSE 'run_result' END AS event,
           block ->> ['type', 'text'] AS b,
           -- a function call's arguments are JSON written as a string
           TRY_CAST(arguments AS JSON) ->> ['cmd', 'command', 'sql', 'code'] AS args,
           item_arguments ->> ['sql', 'statement', 'command', 'code'] AS run_args
    FROM codex_parts
), codex_events AS (
    SELECT 'codex' AS source, session_id, parent_session_id, is_subagent, agent_path,
           line_number, part, byte_offset, bytes, model, line_type, line, item_id, is_nested_run,
           -- a run's line is written when it finishes; the item also says when it started
           CASE event WHEN 'run_call' THEN coalesce(to_timestamp(started_ms / 1000), ts)
                      WHEN 'run_result' THEN coalesce(to_timestamp(completed_ms / 1000), ts)
                      ELSE ts END AS ts,
           concat_ws('/', line_type, payload_type, item_type) AS entry_type,
           CASE WHEN event = 'message' THEN CASE role WHEN 'user' THEN 'user' WHEN 'assistant' THEN 'assistant' ELSE 'system' END
                -- a message from another agent is this thread's input; one it sent is its output
                WHEN event = 'agent_message' THEN CASE WHEN author = agent_path THEN 'assistant' ELSE 'user' END
                WHEN event IN ('function_call_output', 'custom_tool_call_output', 'tool_search_output', 'run_result') THEN 'tool'
                WHEN event = 'line' THEN 'system'
                ELSE 'assistant' END AS speaker,
           CASE WHEN event IN ('message', 'agent_message') THEN CASE WHEN b[1] = 'input_image' THEN 'image' ELSE 'message' END
                WHEN event = 'reasoning' THEN 'thinking'
                WHEN event IN ('function_call', 'custom_tool_call', 'tool_search_call', 'run_call') THEN 'tool_call'
                WHEN event IN ('function_call_output', 'custom_tool_call_output', 'tool_search_output', 'run_result') THEN 'tool_result'
                WHEN event = 'compaction' THEN 'summary'
                WHEN line_type = 'compacted' THEN 'summary'
                WHEN payload_type = 'turn_aborted' THEN 'notice'
                ELSE 'state' END AS kind,
           CASE WHEN event IN ('function_call', 'custom_tool_call') THEN concat_ws('__', namespace, name)
                WHEN event IN ('run_call', 'run_result') THEN CASE item_type
                    WHEN 'CommandExecution' THEN 'exec_command'
                    WHEN 'McpToolCall' THEN concat_ws('__', 'mcp', server, tool)
                    WHEN 'FileChange' THEN 'apply_patch'
                    WHEN 'Extension' THEN item_kind
                    WHEN 'ImageView' THEN 'view_image'
                    WHEN 'DynamicToolCall' THEN concat_ws('__', item_namespace, tool)
                    WHEN 'CollabAgentToolCall' THEN concat_ws('__', 'collaboration', tool) END
                END AS tool_name,
           -- an item_completed line that repeats a call's status names the call by item_id
           CASE WHEN line_type = 'response_item' THEN call_id ELSE item_id END AS tool_call_id,
           CASE event
                WHEN 'message' THEN b[2]
                -- an agent message's payload part is encrypted; its readable part names sender and task
                WHEN 'agent_message' THEN list_aggregate(content_parts ->> '$[*].text', 'string_agg', e'\n')
                WHEN 'reasoning' THEN list_aggregate(summary_parts ->> '$[*].text', 'string_agg', e'\n')
                WHEN 'function_call' THEN coalesce(args[1], args[2], args[3], args[4], arguments)
                WHEN 'custom_tool_call' THEN input
                -- an output is a string or text parts (an exec script's output opens with a text part)
                WHEN 'function_call_output' THEN coalesce(list_aggregate(output ->> '$[*].text', 'string_agg', e'\n'), output_text)
                WHEN 'custom_tool_call_output' THEN coalesce(list_aggregate(output ->> '$[*].text', 'string_agg', e'\n'), output_text)
                WHEN 'run_call' THEN CASE item_type
                    WHEN 'CommandExecution' THEN script
                    WHEN 'McpToolCall' THEN coalesce(run_args[1], run_args[2], run_args[3], run_args[4], item_arguments::VARCHAR)
                    WHEN 'FileChange' THEN changes::VARCHAR
                    WHEN 'Extension' THEN coalesce(query, action::VARCHAR)
                    WHEN 'ImageView' THEN path
                    ELSE coalesce(item_arguments, receivers)::VARCHAR END
                WHEN 'run_result' THEN CASE item_type
                    WHEN 'CommandExecution' THEN aggregated_output
                    WHEN 'McpToolCall' THEN coalesce(list_aggregate(result_content ->> '$[*].text', 'string_agg', e'\n'), item_error)
                    WHEN 'FileChange' THEN concat_ws(e'\n', stdout, stderr)
                    WHEN 'Extension' THEN results::VARCHAR
                    WHEN 'DynamicToolCall' THEN list_aggregate(content_items ->> '$[*].text', 'string_agg', e'\n') END
                WHEN 'line' THEN CASE WHEN line_type = 'compacted' THEN summary_text
                                      WHEN payload_type = 'turn_aborted' THEN reason END
                END AS content,
           CASE WHEN event = 'custom_tool_call' THEN CASE name WHEN 'exec' THEN 'javascript' WHEN 'apply_patch' THEN 'patch' ELSE 'text' END
                WHEN event = 'function_call' THEN CASE WHEN coalesce(args[1], args[2]) IS NOT NULL THEN 'shell'
                                                       WHEN args[3] IS NOT NULL THEN 'sql'
                                                       WHEN args[4] IS NOT NULL THEN 'javascript'
                                                       ELSE 'json' END
                WHEN event = 'run_call' THEN CASE WHEN item_type = 'CommandExecution' THEN 'shell'
                                                  WHEN item_type <> 'McpToolCall' THEN 'json'
                                                  WHEN coalesce(run_args[1], run_args[2]) IS NOT NULL THEN 'sql'
                                                  WHEN run_args[3] IS NOT NULL THEN 'shell'
                                                  WHEN run_args[4] IS NOT NULL THEN 'javascript'
                                                  ELSE 'json' END
                ELSE 'text' END AS content_format,
           CASE WHEN event IN ('function_call_output', 'custom_tool_call_output')
                    -- the exec runtime opens a failed script's output with this line
                    THEN coalesce(starts_with(content, 'Script failed'), false)
                WHEN event IN ('run_call', 'message', 'agent_message', 'reasoning', 'function_call', 'custom_tool_call') THEN false
                -- a run's result, or a line repeating a call's status
                WHEN item_status = 'failed' THEN true
                WHEN exit_code <> 0 THEN true
                WHEN result_is_error THEN true
                WHEN NOT success THEN true
                WHEN payload_type = 'turn_aborted' THEN true
                ELSE false END AS is_error
    FROM codex_fields
), events AS (
    SELECT * EXCLUDE (i) FROM claude_events
    UNION ALL BY NAME
    SELECT * FROM codex_events
),

-- What a tool call's input runs. Parse trees are unnested in the select list and folded back per call with list().
calls AS (
    SELECT line_number, part, content_format, content FROM events WHERE kind = 'tool_call'
), shell_words AS (
    -- a command_name node is the program a command runs; an ERROR node is text the parser could not place
    SELECT line_number, part, node.node_id, node.type, node.peek
    FROM (SELECT line_number, part, unnest(parse_ast_list(content, 'bash')) AS node FROM calls WHERE content_format = 'shell')
    WHERE node.type IN ('command_name', 'ERROR')
), programs AS (
    SELECT line_number, part, list(peek ORDER BY node_id) AS programs FROM shell_words WHERE type = 'command_name' GROUP BY ALL
), shell_errors AS (
    SELECT DISTINCT line_number, part FROM shell_words WHERE type = 'ERROR'
), sql_texts AS (
    -- DuckDB's parser splits the input into statements and prints each back in its own words. parse_statements cannot
    -- print CREATE SECRET and fails the whole query (try() does not catch it), so SQL naming a secret is not split.
    SELECT line_number, part, parse_statements(content) AS statements
    FROM calls WHERE content_format = 'sql' AND is_parsable(content) AND NOT contains(upper(content), 'SECRET')
), sql_statements AS (
    SELECT line_number, part, unnest(statements) AS statement, generate_subscripts(statements, 1) AS idx FROM sql_texts
), statement_kinds AS (
    SELECT line_number, part, list(CASE first_word WHEN 'with' THEN 'select' ELSE first_word END ORDER BY idx) AS statement_kinds
    FROM (SELECT *, lower(string_split(ltrim(statement, ' ('), ' ')[1]) AS first_word FROM sql_statements)
    GROUP BY ALL
), sql_nodes AS (
    -- sitting_duck's SQL parse: function calls, and the tables INSERT, UPDATE, CREATE VIEW and DROP TABLE name
    SELECT line_number, part, node.node_id, node.parent_id, node.type, node.name
    FROM (SELECT line_number, part, unnest(parse_ast_list(content, 'sql')) AS node FROM calls WHERE content_format = 'sql')
    WHERE node.type IN ('invocation', 'object_reference', 'insert', 'update', 'create_view', 'drop_table')
), table_names AS (
    SELECT line_number, part, concat_ws('.', nullif(ref.schema, 'main'), ref.table) AS table_name
    FROM (SELECT line_number, part, unnest(parse_tables(statement)) AS ref FROM sql_statements)
    WHERE ref.context NOT IN ('cte', 'from_cte')
    UNION ALL
    SELECT o.line_number, o.part, o.name
    FROM sql_nodes o JOIN sql_nodes target
      ON target.line_number = o.line_number AND target.part = o.part AND target.node_id = o.parent_id
    WHERE o.type = 'object_reference' AND target.type IN ('insert', 'update', 'create_view', 'drop_table')
), tables AS (
    SELECT line_number, part, list(DISTINCT table_name) AS tables FROM table_names GROUP BY ALL
), function_names AS (
    SELECT line_number, part, unnest(parse_function_names(statement)) AS function_name FROM sql_statements
    UNION ALL
    SELECT line_number, part, name FROM sql_nodes WHERE type = 'invocation'
), functions AS (
    -- parser_tools also lists operators (~~, ->>, -) as functions; a function's name starts with a letter
    SELECT line_number, part, list(DISTINCT lower(function_name)) AS functions
    FROM function_names WHERE lower(function_name[1]) BETWEEN 'a' AND 'z' GROUP BY ALL
)
SELECT e.source, e.session_id, e.parent_session_id, e.is_subagent, e.agent_path, {{ transcript }} AS transcript,
       e.line_number, e.part, e.byte_offset, e.bytes, e.ts, e.speaker, e.kind, e.tool_name, e.tool_call_id,
       e.content, e.content_format, e.is_error, e.model, e.entry_type, e.line_type, e.item_id, e.is_nested_run,
       p.programs, CASE WHEN e.content_format = 'shell' AND e.kind = 'tool_call' THEN x.line_number IS NULL END AS shell_parses,
       CASE WHEN e.content_format = 'sql' AND e.kind = 'tool_call' THEN is_parsable(e.content) END AS sql_parses,
       k.statement_kinds, t.tables, fn.functions,
       CASE WHEN e.part = 1 THEN d.fields END AS fields, CASE WHEN e.part = 1 THEN e.line END AS line
FROM events e
LEFT JOIN fields d USING (line_number)
LEFT JOIN programs p USING (line_number, part)
LEFT JOIN shell_errors x USING (line_number, part)
LEFT JOIN statement_kinds k USING (line_number, part)
LEFT JOIN tables t USING (line_number, part)
LEFT JOIN functions fn USING (line_number, part)
$append$ AS append
), created AS (
    -- the table, if it does not exist yet: the append statement over no lines
    SELECT append, array_agg(selfdispatch(tera_render(append, {
               'into': 'CREATE TABLE IF NOT EXISTS agent.stream AS', 'reader': 'parse_lines', 'source': quote_literal(''),
               'lines': quote_literal('1-'), 'agent': quote_literal('claude'), 'transcript': quote_literal(''),
               'session_id': quote_literal(''), 'parent_session_id': quote_literal(''), 'is_subagent': 'false',
               'agent_path': quote_literal(''), 'model': quote_literal('')}::JSON, autoescape := false))) AS receipts
    FROM template GROUP BY append
), program AS (
    -- the refresh, with the append statement written into it; built from created's row, so it runs after the table exists
    SELECT list_transform(receipts, r -> {'status': r.status, 'body': r.body}) AS created, tera_render($refresh$
WITH transcripts AS (
    SELECT file AS transcript, 'claude' AS agent FROM glob('~/.claude/projects/**/*.jsonl')
    UNION ALL
    SELECT file, 'codex' FROM glob('~/.codex/sessions/**/*.jsonl*')
    UNION ALL
    SELECT file, 'codex' FROM glob('~/.codex/archived_sessions/*.jsonl*')
), stored AS (
    SELECT transcript, max(line_number) AS last_line, max(byte_offset + bytes) AS read_to,
           max(session_id) AS session_id, max(parent_session_id) AS parent_session_id, max(agent_path) AS agent_path,
           arg_max(model, line_number) AS model
    FROM agent.stream GROUP BY transcript
), work AS (
    SELECT t.transcript AS path, quote_literal(t.transcript) AS transcript, file_extension(t.transcript) = '.zst' AS compressed,
           coalesce(s.last_line, 0) + 1 AS first_line,
           'INSERT INTO agent.stream BY NAME' AS into, 'read_lines' AS reader,
           -- a .zst rollout is decompressed through a pipe that stops after the window's last line
           quote_literal(CASE WHEN compressed THEN 'zstd -dc ' || t.transcript || ' | sed ' || (first_line + 1999) || 'q |'
                              ELSE t.transcript END) AS source,
           quote_literal(first_line || '-' || (first_line + 1999)) AS lines,
           quote_literal(t.agent) AS agent,
           -- Claude's ids are in the path: <project>/<session>.jsonl, <project>/<session>/subagents/agent-<id>.jsonl
           file_name(parse_dirpath(t.transcript)) = 'subagents' AS subagent_path,
           quote_literal(CASE WHEN t.agent = 'claude' THEN parse_filename(t.transcript, true) ELSE s.session_id END) AS session_id,
           quote_literal(CASE WHEN t.agent = 'codex' THEN s.parent_session_id
                              WHEN subagent_path THEN parse_filename(parse_dirpath(parse_dirpath(t.transcript))) END) AS parent_session_id,
           subagent_path::VARCHAR AS is_subagent,
           quote_literal(s.agent_path) AS agent_path, quote_literal(s.model) AS model,
           CASE WHEN compressed THEN file_size(t.transcript) ELSE file_size(t.transcript) - coalesce(s.read_to, 0) END AS pending
    FROM transcripts t LEFT JOIN stored s USING (transcript)
    -- a .zst rollout is finished but its length is unknown until read: one more window is due while every window so
    -- far came back full (a rollout of exactly n x 2,000 lines asks once a run for a window that comes back empty)
    WHERE CASE WHEN compressed THEN coalesce(s.last_line % 2000 = 0, true) ELSE file_size(t.transcript) > coalesce(s.read_to, 0) END
), queued AS (
    SELECT * EXCLUDE (queued_before) FROM (
        SELECT *, sum(pending) OVER (ORDER BY pending, path) - pending AS queued_before FROM work)
    WHERE queued_before < 64000000
), statements AS (
    SELECT path, tera_render($append${{ append }}$append$, w::JSON, autoescape := false) AS sql FROM queued w
), posted AS (
    SELECT array_agg({'path': path, 'receipt': selfdispatch(sql)}) AS receipts FROM statements
)
SELECT r.path, r.receipt.status, r.receipt.body, r.receipt.error FROM posted CROSS JOIN UNNEST(receipts) AS t(r);
$refresh$, {'append': append}::JSON, autoescape := false) AS sql
    FROM created
), views AS (
    -- the views over the table, posted once it exists, as one post: agent.tool_calls reads agent.events
    SELECT sql AS refresh, created,
           list_transform(array_agg(selfdispatch(view_sql)), r -> {'status': r.status, 'body': r.body}) AS views
    FROM (SELECT *, $views$
-- agent.events: the stored events, less the item_completed lines that only repeat a call the thread already made,
-- plus Codex thread names, which live outside the rollout in ~/.codex/session_index.jsonl.
CREATE OR REPLACE VIEW agent.events AS
WITH repeats AS (
    SELECT DISTINCT transcript, tool_call_id AS item_id FROM agent.stream
    WHERE source = 'codex' AND line_type = 'response_item' AND kind = 'tool_call'
), threads AS (
    SELECT transcript, session_id, parent_session_id, is_subagent FROM agent.stream WHERE source = 'codex' AND line_number = 1
)
SELECT * EXCLUDE (byte_offset, bytes, item_id, is_nested_run, fields, line)
FROM agent.stream s ANTI JOIN repeats r ON s.is_nested_run AND r.transcript = s.transcript AND r.item_id = s.item_id
UNION ALL BY NAME
SELECT 'codex' AS source, t.session_id, t.parent_session_id, t.is_subagent, t.transcript, 1 AS part, n.updated_at AS ts,
       'session_index' AS entry_type, 'system' AS speaker, 'title' AS kind, n.title AS content, 'text' AS content_format,
       false AS is_error
FROM threads t JOIN agent.titles n ON n.id::VARCHAR = t.session_id;
-- agent.tool_calls: one row per tool call, with what its input runs (parsed when it was stored) and its result: the
-- first event with the same tool_call_id at or after the call (a forked Codex rollout or a resumed Claude transcript
-- repeats earlier calls and results under the same id).
CREATE OR REPLACE VIEW agent.tool_calls AS
WITH calls AS (
    SELECT * FROM agent.events WHERE kind = 'tool_call'
), results AS (
    SELECT transcript, tool_call_id, ts AS result_ts, line_number AS result_line_number, is_error, content AS output
    FROM agent.events WHERE kind = 'tool_result'
)
SELECT c.source, c.session_id, c.parent_session_id, c.is_subagent, c.transcript, c.line_number, c.ts, c.model,
       c.tool_name, c.tool_call_id, c.content_format AS input_format, c.content AS input,
       c.programs, c.shell_parses, c.sql_parses, c.statement_kinds, c.tables, c.functions,
       r.is_error, r.result_ts, r.result_ts - c.ts AS took, r.result_line_number, r.output
FROM calls c
ASOF LEFT JOIN results r ON r.transcript = c.transcript AND r.tool_call_id = c.tool_call_id AND r.result_line_number >= c.line_number;
-- agent.keys: every path the transcripts use, at every depth, by source and line type, from each line's stored
-- fields (an array's elements are one path, [0]). A field Claude Code or Codex adds shows up here on the next
-- refresh with no code change, and reads as json_extract(line, path) until a column names it.
CREATE OR REPLACE VIEW agent.keys AS
WITH used AS (
    SELECT source, line_type, ts, unnest(fields) AS field FROM agent.stream WHERE part = 1
)
SELECT source, line_type, field.path, list(DISTINCT field.type) AS types, min(ts) AS first_seen, max(ts) AS last_seen,
       count() AS lines
FROM used GROUP BY ALL;
$views$ AS view_sql FROM program)
    GROUP BY ALL
), posted AS (
    -- the first refresh, which on an empty table is the initial fill
    SELECT refresh, created, views, array_agg(selfdispatch(refresh)) AS receipts FROM views GROUP BY ALL
)
SELECT cron(refresh, '0 * * * * *') AS job, created, views, r.status, r.body, r.error
FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

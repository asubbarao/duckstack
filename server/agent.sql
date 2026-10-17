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
-- means no rows, so nothing is posted. file_row_number is each row's place in its session's file, from which
-- agent.events numbers the lines of each transcript.
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
SELECT * FROM read_parquet([{{ files | join(sep=", ") }}], union_by_name := true, file_row_number := true)
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

-- agent.events: one row per thing that happened in a transcript, Claude Code and Codex in one shape, read from the
-- raw lines in agent.lines. A line holding several content blocks gives one event per block (`part` counts them from
-- 1); every other line gives one event, so each stored line appears at least once.
--   session_id / parent_session_id  Claude: the transcript file's name (a subagent's is agent-<id>) and, for a
--            subagent, its session's; Codex: the thread id and, for a subagent thread, its parent thread's
--   line_number  the line's number in its transcript file, from 1, counting the lines the JSON reader kept
--   ts       the line's time (`at` is a reserved word in DuckDB 1.5: `SELECT at FROM t` does not parse); NULL on
--            lines that carry none (titles, bookkeeping)
--   speaker  user | assistant | system | tool (a tool's result is the tool speaking)
--   kind     message | thinking | tool_call | tool_result | image | summary | title | context (text the harness
--            added to the model's input) | notice (harness status and errors) | state (bookkeeping lines)
--   content  the text; for a tool call its command, SQL or code, else its arguments as JSON; for a result its output
--   content_format  shell | sql | javascript | patch | json | text: how to read content
--   entry_type  the transcript's own names for what produced the event (line type / block or payload type)
-- Memory: a JSON function keeps a parsed copy of the largest 2048-row chunk it has read, per thread, and Codex
-- payloads reach 80 MB a chunk. So each JSON document is parsed once (`doc ->> [paths]` returns the listed fields as
-- one list, which the next step names), and each source is one pipeline: Claude's or Codex's branches run side by
-- side and would each hold their own copies. A part holding several texts is read with ->> '$[*].text' and joined.
CREATE OR REPLACE VIEW agent.events AS
WITH starts AS (
    -- a session's Parquet holds its transcripts back to back, so a line's number counts from its transcript's first row
    SELECT transcript, min(file_row_number) AS first_row FROM agent.lines GROUP BY transcript
), lines AS NOT MATERIALIZED (
    -- only the fields read below; agent.lines has ~180 columns, some named like the columns made here
    SELECT l.transcript, l.file_row_number - s.first_row + 1 AS line_number, (l.timestamp ->> '$')::TIMESTAMPTZ AS ts,
           l.type ->> '$' AS line_type, l.payload, l.message, l.isMeta, l.origin, l.isCompactSummary,
           l.isApiErrorMessage, l.attachment, l.rendered, l.subtype, l.level, l.error, l.aiTitle, l.customTitle,
           l.content AS line_content
    FROM agent.lines l JOIN starts s USING (transcript)
),

-- Claude Code: <project>/<session>.jsonl, and <project>/<session>/subagents/agent-<id>.jsonl for its subagents.
-- A user or assistant line's message.content is a string or an array of blocks; each block is an event (a string is
-- one text block). Every other line (system, attachment, titles, bookkeeping) is one event.
claude_lines AS (
    SELECT * EXCLUDE (payload, message), contains(transcript, '/subagents/') AS is_subagent,
           parse_filename(transcript, true) AS session_id,
           CASE WHEN is_subagent THEN parse_filename(parse_dirpath(parse_dirpath(transcript))) END AS parent_session_id,
           message -> ['content', 'model'] AS m,
           CASE WHEN line_type NOT IN ('user', 'assistant') THEN [NULL::JSON]
                WHEN json_type(m[1]) = 'ARRAY' THEN m[1]::JSON[]
                ELSE [json_object('type', 'text', 'text', m[1] ->> '$')] END AS blocks
    FROM lines WHERE NOT contains(transcript, '/.codex/')
), claude_parts AS (
    -- unnest in the select list streams; a lateral UNNEST joins back on every column it reads
    SELECT * EXCLUDE (blocks), unnest(blocks) AS block, generate_subscripts(blocks, 1) AS part FROM claude_lines
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
    SELECT 'claude' AS source, session_id, parent_session_id, is_subagent, transcript, line_number, part, ts, model,
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
                ELSE false END AS is_error
    FROM claude_fields
),

-- Codex: one rollout file per thread. Its first session_meta line names the thread and, for a subagent, its parent
-- (a forked rollout then repeats its parent's session_meta). turn_context lines name each turn's model.
codex_payloads AS NOT MATERIALIZED (
    -- payload: the line's own fields, and for an item_completed line the item's (a tool the exec script ran)
    SELECT transcript, line_number, ts, line_type,
           payload ->> ['type', 'call_id', 'name', 'namespace', 'role', 'author', 'input', 'arguments', 'output',
                        '$.internal_chat_message_metadata_passthrough.turn_id', 'turn_id', 'model', 'reason', 'message',
                        'started_at_ms', 'completed_at_ms', 'id', 'parent_thread_id', 'agent_path',
                        '$.item.type', '$.item.id', '$.item.status', '$.item.exit_code', '$.item.server', '$.item.tool',
                        '$.item.namespace', '$.item.kind', '$.item.query', '$.item.path', '$.item.aggregated_output',
                        '$.item.stdout', '$.item.stderr', '$.item.error', '$.item.success', '$.item.command[2]',
                        '$.item.result.isError'] AS f,
           payload -> ['content', 'output', 'summary', '$.item.arguments', '$.item.result.content', '$.item.changes',
                       '$.item.results', '$.item.content_items', '$.item.action', '$.item.receiver_thread_ids'] AS j
    FROM lines WHERE contains(transcript, '/.codex/')
), codex AS NOT MATERIALIZED (
    SELECT transcript, line_number, ts, line_type,
           f[1] AS payload_type, f[2] AS call_id, f[3] AS name, f[4] AS namespace, f[5] AS role, f[6] AS author,
           f[7] AS input, f[8] AS arguments, f[9] AS output_text, coalesce(f[10], f[11]) AS turn_id, f[12] AS turn_model,
           f[13] AS reason, f[14] AS summary_text, f[15]::BIGINT AS started_ms, f[16]::BIGINT AS completed_ms,
           f[17] AS id, f[18] AS parent_thread_id, f[19] AS meta_agent_path,
           f[20] AS item_type, f[21] AS item_id, f[22] AS item_status, f[23]::BIGINT AS exit_code, f[24] AS server,
           f[25] AS tool, f[26] AS item_namespace, f[27] AS item_kind, f[28] AS query, f[29] AS path,
           f[30] AS aggregated_output, f[31] AS stdout, f[32] AS stderr, f[33] AS item_error, f[34]::BOOLEAN AS success,
           -- a command is [shell, '-lc', script]
           f[35] AS script, f[36]::BOOLEAN AS result_is_error,
           j[1] AS content_parts, j[2] AS output, j[3] AS summary_parts, j[4] AS item_arguments, j[5] AS result_content,
           j[6] AS changes, j[7] AS results, j[8] AS content_items, j[9] AS action, j[10] AS receivers
    FROM codex_payloads
), threads AS (
    SELECT transcript, arg_min({'session_id': id, 'parent_session_id': parent_thread_id, 'agent_path': meta_agent_path}, line_number) AS thread
    FROM codex WHERE line_type = 'session_meta' GROUP BY transcript
), turns AS (
    SELECT transcript, turn_id, arg_max(turn_model, line_number) AS model FROM codex WHERE line_type = 'turn_context' GROUP BY ALL
), tool_call_ids AS (
    SELECT DISTINCT transcript, call_id FROM codex WHERE line_type = 'response_item' AND payload_type IN ('function_call', 'custom_tool_call')
), codex_lines AS (
    SELECT c.*, t.thread.session_id AS session_id, t.thread.parent_session_id AS parent_session_id,
           parent_session_id IS NOT NULL AS is_subagent, coalesce(t.thread.agent_path, '/root') AS agent_path, m.model,
           -- an item_completed line for a tool the exec script ran itself (a shell command, an MCP tool, a patch) has
           -- no response_item call of its own; one whose id is a call's only repeats that call
           k.call_id AS reported_call_id,
           CASE WHEN item_type IN ('CommandExecution', 'McpToolCall', 'FileChange', 'Extension', 'ImageView',
                                   'DynamicToolCall', 'CollabAgentToolCall') THEN k.call_id IS NULL
                ELSE false END AS is_nested_run,
           -- events per line: a message's content parts, a nested run's call and result, else the line itself
           CASE WHEN payload_type = 'message' THEN content_parts::JSON[]
                WHEN is_nested_run THEN [NULL::JSON, NULL::JSON]
                ELSE [NULL::JSON] END AS blocks
    FROM codex c
    LEFT JOIN threads t USING (transcript)
    LEFT JOIN turns m USING (transcript, turn_id)
    LEFT JOIN tool_call_ids k ON k.transcript = c.transcript AND k.call_id = c.item_id
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
    SELECT 'codex' AS source, session_id, parent_session_id, is_subagent, transcript, line_number, part, model,
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
           CASE WHEN line_type = 'response_item' THEN call_id
                WHEN is_nested_run THEN item_id
                ELSE reported_call_id END AS tool_call_id,
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
), codex_titles AS (
    -- Codex keeps thread names outside the rollout, in ~/.codex/session_index.jsonl
    SELECT 'codex' AS source, t.thread.session_id AS session_id, t.thread.parent_session_id AS parent_session_id,
           parent_session_id IS NOT NULL AS is_subagent,
           t.transcript, NULL::BIGINT AS line_number, 1 AS part, n.updated_at AS ts, 'session_index' AS entry_type,
           'system' AS speaker, 'title' AS kind, n.title AS content, 'text' AS content_format, false AS is_error
    FROM threads t JOIN agent.titles n ON n.id::VARCHAR = t.thread.session_id
)
SELECT source, session_id, parent_session_id, is_subagent, transcript, line_number, part, ts, speaker, kind,
       tool_name, tool_call_id, content, content_format, is_error, model, entry_type
FROM (
    SELECT * EXCLUDE (i) FROM claude_events
    UNION ALL BY NAME SELECT * FROM codex_events
    UNION ALL BY NAME SELECT * FROM codex_titles
);

-- agent.tool_calls: one row per tool call, with its result (same transcript, same tool_call_id) and what it ran, so a
-- question like "which calls ran git status" or "which dev queries read agent.lines and failed" is a WHERE.
--   input_format     shell | sql | javascript | patch | json | text
--   programs         shell input: the program each command runs, in order (git, rg, duckdb ...), from sitting_duck's
--                    bash parse
--   shell_parses     shell input: the bash parse has no error node
--   sql_parses       SQL input: DuckDB's parser accepts it (parser_tools is_parsable)
--   statement_kinds  SQL input: each statement's kind (select, insert, create, copy ...), the first word of the
--                    statement as DuckDB's parser prints it back; a WITH query is a select
--   tables           SQL input: tables read (parser_tools, SELECT statements) and written (sitting_duck: the target of
--                    INSERT, UPDATE, CREATE VIEW, DROP TABLE)
--   functions        SQL input: functions called, parser_tools' names plus sitting_duck's calls, which include table
--                    functions (read_parquet, read_conversations) that parser_tools does not see
--   is_error         from the result; NULL when no result was recorded
-- Parse trees are unnested in the select list (a lateral UNNEST would join back on the whole input text) and folded
-- back per call with list().
CREATE OR REPLACE VIEW agent.tool_calls AS
WITH calls AS (
    SELECT source, session_id, parent_session_id, is_subagent, transcript, line_number, part, ts, model, tool_name, tool_call_id,
           content_format AS input_format, content AS input
    FROM agent.events WHERE kind = 'tool_call'
), results AS (
    SELECT transcript, tool_call_id, ts AS result_ts, line_number AS result_line_number, is_error, content AS output
    FROM agent.events WHERE kind = 'tool_result'
), shell_nodes AS (
    -- the bash parse, one row per node
    SELECT transcript, line_number, part, unnest(parse_ast_list(input, 'bash')) AS node FROM calls WHERE input_format = 'shell'
), shell_words AS (
    -- a command_name node is the program a command runs; an ERROR node is text the parser could not place
    SELECT transcript, line_number, part, node.node_id, node.type, node.peek FROM shell_nodes WHERE node.type IN ('command_name', 'ERROR')
), programs AS (
    SELECT transcript, line_number, part, list(peek ORDER BY node_id) AS programs FROM shell_words WHERE type = 'command_name' GROUP BY ALL
), shell_errors AS (
    SELECT DISTINCT transcript, line_number, part FROM shell_words WHERE type = 'ERROR'
), sql_texts AS (
    -- DuckDB's parser splits the input into statements and prints each back in its own words. parse_statements cannot
    -- print CREATE SECRET and fails the whole query (try() does not catch it), so SQL naming a secret is not split.
    SELECT transcript, line_number, part, parse_statements(input) AS statements
    FROM calls WHERE input_format = 'sql' AND is_parsable(input) AND NOT contains(upper(input), 'SECRET')
), sql_statements AS (
    SELECT transcript, line_number, part, unnest(statements) AS statement, generate_subscripts(statements, 1) AS idx FROM sql_texts
), statement_kinds AS (
    SELECT transcript, line_number, part, list(CASE first_word WHEN 'with' THEN 'select' ELSE first_word END ORDER BY idx) AS statement_kinds
    FROM (SELECT *, lower(string_split(ltrim(statement, ' ('), ' ')[1]) AS first_word FROM sql_statements)
    GROUP BY ALL
), sql_nodes AS (
    -- sitting_duck's SQL parse: function calls, and the tables INSERT, UPDATE, CREATE VIEW and DROP TABLE name
    SELECT transcript, line_number, part, node.node_id, node.parent_id, node.type, node.name
    FROM (SELECT transcript, line_number, part, unnest(parse_ast_list(input, 'sql')) AS node FROM calls WHERE input_format = 'sql')
    WHERE node.type IN ('invocation', 'object_reference', 'insert', 'update', 'create_view', 'drop_table')
), table_refs AS (
    SELECT transcript, line_number, part, unnest(parse_tables(statement)) AS ref FROM sql_statements
), table_names AS (
    SELECT transcript, line_number, part, concat_ws('.', nullif(ref.schema, 'main'), ref.table) AS table_name
    FROM table_refs WHERE ref.context NOT IN ('cte', 'from_cte')
    UNION ALL
    SELECT o.transcript, o.line_number, o.part, o.name
    FROM sql_nodes o JOIN sql_nodes target
      ON target.transcript = o.transcript AND target.line_number = o.line_number AND target.part = o.part AND target.node_id = o.parent_id
    WHERE o.type = 'object_reference' AND target.type IN ('insert', 'update', 'create_view', 'drop_table')
), tables AS (
    SELECT transcript, line_number, part, list(DISTINCT table_name) AS tables FROM table_names GROUP BY ALL
), function_names AS (
    SELECT transcript, line_number, part, unnest(parse_function_names(statement)) AS function_name FROM sql_statements
    UNION ALL
    SELECT transcript, line_number, part, name FROM sql_nodes WHERE type = 'invocation'
), functions AS (
    -- parser_tools also lists operators (~~, ->>, -) as functions; a function's name starts with a letter
    SELECT transcript, line_number, part, list(DISTINCT lower(function_name)) AS functions
    FROM function_names WHERE lower(function_name[1]) BETWEEN 'a' AND 'z' GROUP BY ALL
)
SELECT c.source, c.session_id, c.parent_session_id, c.is_subagent, c.transcript, c.line_number, c.ts, c.model,
       c.tool_name, c.tool_call_id, c.input_format, c.input,
       p.programs,
       CASE WHEN c.input_format = 'shell' THEN e.transcript IS NULL END AS shell_parses,
       CASE WHEN c.input_format = 'sql' THEN is_parsable(c.input) END AS sql_parses,
       k.statement_kinds, t.tables, f.functions,
       r.is_error, r.result_ts, r.result_ts - c.ts AS took, r.result_line_number, r.output
FROM calls c
LEFT JOIN programs p USING (transcript, line_number, part)
LEFT JOIN shell_errors e USING (transcript, line_number, part)
LEFT JOIN statement_kinds k USING (transcript, line_number, part)
LEFT JOIN tables t USING (transcript, line_number, part)
LEFT JOIN functions f USING (transcript, line_number, part)
-- the first result at or after the call: a forked Codex rollout or a resumed Claude transcript repeats earlier calls
-- and results under the same id
ASOF LEFT JOIN results r ON r.transcript = c.transcript AND r.tool_call_id = c.tool_call_id AND r.result_line_number >= c.line_number;


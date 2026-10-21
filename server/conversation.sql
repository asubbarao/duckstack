-- agent.conversation, a view over stream.blocks (blocks.sql), posted at boot after messages.sql: messages and tool calls
-- as one relation, every stream.blocks column. Each tool call (tool_part 'call': Claude tool_use, Codex function_call /
-- custom_tool_call) carries its result (tool_part 'result'), joined on (file_path, tool_use_id): returned_at, took,
-- result_text, is_error, result_bytes, result_block_key; a call's message_content is its command. The tool calls are
-- `WHERE tool_part = 'call'`. paired says whether a call or result has its other half in the same file; a result without
-- one (NOT paired) is a row of its own, so nothing is dropped. block_key matches stream.blocks, so BM25
-- (fts_main_blocks.match_bm25(block_key, '...')) scores both.
WITH intent AS (
    SELECT $v$
CREATE OR REPLACE VIEW agent.conversation AS
WITH live AS (
    SELECT *, bool_or(tool_part = 'call') OVER pair AND bool_or(tool_part = 'result') OVER pair AS paired
    FROM stream.blocks WHERE NOT is_repeat
    WINDOW pair AS (PARTITION BY file_path, tool_use_id)
), results AS (
    SELECT file_path, tool_use_id, timestamp AS returned_at, message_content AS result_text, is_error,
           content_bytes AS result_bytes, block_key AS result_block_key
    FROM live WHERE tool_part = 'result' AND paired
)
SELECT live.* REPLACE (coalesce(results.is_error, live.is_error) AS is_error), results.* EXCLUDE (file_path, tool_use_id, is_error),
       returned_at - timestamp AS took
FROM live LEFT JOIN results USING (file_path, tool_use_id)
WHERE (tool_part, paired) IS DISTINCT FROM ('result', true)
$v$ AS conversation_sql
), conversation_step AS (
    SELECT array_agg(selfdispatch(conversation_sql)) AS receipts FROM intent
)
SELECT r.* FROM conversation_step CROSS JOIN UNNEST(receipts) AS t(r);

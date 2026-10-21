-- The tool-call views over stream.blocks (blocks.sql), posted at boot after messages.sql.
-- agent.tool_calls: one row per tool call (tool_part 'call': Claude tool_use, Codex function_call / custom_tool_call),
-- every stream.blocks column of the call (timestamp and content_bytes are the call's), with its result (tool_part
-- 'result') joined on (file_path, tool_use_id): returned_at, took, result_text, is_error, result_bytes, result_block_key.
-- agent.conversation: messages and tool calls as one relation, every column of both. A call row's message_content is
-- its command; a message row has the result columns NULL. block_key matches stream.blocks, so BM25
-- (fts_main_blocks.match_bm25(block_key, '...')) scores both. It reads agent.tool_calls, so it is posted from that receipt.
WITH tool_calls_step AS (
    SELECT array_agg(selfdispatch($c$
CREATE OR REPLACE VIEW agent.tool_calls AS
WITH calls AS (
    SELECT * EXCLUDE (is_error) FROM stream.blocks WHERE NOT is_repeat AND tool_part = 'call'
), results AS (
    SELECT file_path, tool_use_id, timestamp AS returned_at, message_content AS result_text, is_error,
           content_bytes AS result_bytes, block_key AS result_block_key
    FROM stream.blocks WHERE NOT is_repeat AND tool_part = 'result'
)
SELECT *, returned_at - timestamp AS took FROM calls LEFT JOIN results USING (file_path, tool_use_id)
$c$)) AS receipts
), conversation_step AS (
    SELECT array_agg(selfdispatch($v$
CREATE OR REPLACE VIEW agent.conversation AS
SELECT * FROM stream.blocks WHERE NOT is_repeat AND tool_part IS NULL
UNION ALL BY NAME
SELECT * FROM agent.tool_calls
$v$)) AS receipts
    FROM tool_calls_step CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200
)
SELECT r.* FROM tool_calls_step CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL SELECT r.* FROM conversation_step CROSS JOIN UNNEST(receipts) AS t(r);

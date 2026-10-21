-- The tool-call views over stream.blocks (blocks.sql), posted at boot after messages.sql.
-- agent.conversation: messages and tool calls as one relation, every stream.blocks column. Each tool call (tool_part
-- 'call': Claude tool_use, Codex function_call / custom_tool_call) carries its result (tool_part 'result'), joined on
-- (file_path, tool_use_id): returned_at, took, result_text, is_error, result_bytes, result_block_key; a call's
-- message_content is its command. block_key matches stream.blocks, so BM25 (fts_main_blocks.match_bm25(block_key,
-- '...')) scores both.
-- agent.tool_calls: the call rows of agent.conversation, posted from its receipt.
WITH intent AS (
    SELECT $v$
CREATE OR REPLACE VIEW agent.conversation AS
WITH live AS (
    SELECT * FROM stream.blocks WHERE NOT is_repeat
), results AS (
    SELECT file_path, tool_use_id, timestamp AS returned_at, message_content AS result_text, is_error,
           content_bytes AS result_bytes, block_key AS result_block_key
    FROM live WHERE tool_part = 'result'
)
SELECT live.* EXCLUDE (is_error), results.* EXCLUDE (file_path, tool_use_id), returned_at - timestamp AS took
FROM live LEFT JOIN results USING (file_path, tool_use_id)
WHERE tool_part IS DISTINCT FROM 'result'
$v$ AS conversation_sql,
           $c$CREATE OR REPLACE VIEW agent.tool_calls AS SELECT * FROM agent.conversation WHERE tool_part = 'call'$c$ AS tool_calls_sql
), conversation_step AS (
    SELECT tool_calls_sql, array_agg(selfdispatch(conversation_sql)) AS receipts FROM intent GROUP BY ALL
), tool_calls_step AS (
    SELECT array_agg(selfdispatch(tool_calls_sql)) AS receipts
    FROM conversation_step CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200
)
SELECT r.* FROM conversation_step CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL SELECT r.* FROM tool_calls_step CROSS JOIN UNNEST(receipts) AS t(r);

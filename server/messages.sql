-- The views over stream.blocks (blocks.sql), posted once at boot after the table exists.
-- agent.messages: stream.blocks without the full text (head, tail), so a 290 KB paste never fills a reply.
-- agent.sessions: one row per session to pick from, then read its blocks by session_id: activity, and its prompts in
-- order (openings); is_near_repeat drops a prompt within rapidfuzz_ratio 90 of the one before.
WITH intent AS (
    SELECT $m$
CREATE OR REPLACE VIEW agent.messages AS
SELECT * EXCLUDE (message_content, tool_input, tool_command), left(message_content, 100) AS head,
       right(message_content, 100) AS tail, left(tool_command, 100) AS tool_command_head
FROM stream.blocks
$m$ AS messages_sql, $s$
CREATE OR REPLACE VIEW agent.sessions AS
WITH prompt AS (
    SELECT session_id, timestamp, head AS opening, lag(head) OVER (PARTITION BY session_id ORDER BY timestamp) AS previous_opening,
           coalesce(rapidfuzz_ratio(head, previous_opening) >= 90, false) AS is_near_repeat
    FROM agent.messages WHERE is_prompt AND NOT is_repeat
), prompts AS (
    SELECT session_id, array_agg(opening ORDER BY timestamp) AS openings
    FROM prompt WHERE NOT is_near_repeat GROUP BY session_id
), activity AS (
    SELECT session_id, source, min(timestamp) AS started, max(timestamp) AS last_active, count(block_key) AS blocks
    FROM agent.messages WHERE NOT is_repeat GROUP BY session_id, source
)
SELECT a.*, len(p.openings) AS prompts, p.openings[1] AS first_prompt, p.openings[-1] AS last_prompt, p.openings
FROM activity a LEFT JOIN prompts p USING (session_id)
$s$ AS sessions_sql
), messages_step AS (
    SELECT sessions_sql, array_agg(selfdispatch(messages_sql)) AS receipts FROM intent GROUP BY sessions_sql
), sessions_step AS (
    SELECT array_agg(selfdispatch(sessions_sql)) AS receipts
    FROM messages_step CROSS JOIN UNNEST(receipts) AS t(r) WHERE r.status = 200 GROUP BY sessions_sql
)
SELECT r.* FROM messages_step CROSS JOIN UNNEST(receipts) AS t(r)
UNION ALL
SELECT r.* FROM sessions_step CROSS JOIN UNNEST(receipts) AS t(r);

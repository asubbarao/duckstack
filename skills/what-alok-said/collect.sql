-- Everything Alok typed to an agent, per session active in the last 14 days: prompts is every typed prompt as its
-- whole stream.blocks row, in order (agent.sessions, server/messages.sql). A reader of one group replaces the WHERE
-- line with WHERE session_id IN (...).
SELECT * EXCLUDE (block_keys) FROM agent.sessions
WHERE last_active > now() - INTERVAL 14 DAY
ORDER BY started;

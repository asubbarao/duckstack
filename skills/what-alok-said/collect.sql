-- Everything Alok typed to an agent in the last 14 days, one row per session, his prompts in order (agent.prompts,
-- server/messages.sql). A reader of one group of sessions adds AND session_id IN (...).
FROM agent.prompts WHERE last_ts > now() - INTERVAL 14 DAY ORDER BY first_ts;

-- Everything Alok typed to an agent in the last 14 days, one row per session, his prompts in order. stream.blocks
-- already parses every transcript and marks is_prompt (typed by a person, harness text excluded) and is_repeat.
WITH typed AS (
    SELECT source, session_id, timestamp, message_content AS text FROM stream.blocks
    WHERE is_prompt AND NOT is_repeat AND timestamp > now() - INTERVAL 14 DAY
)
SELECT source, session_id, min(timestamp) AS first_ts, max(timestamp) AS last_ts, sum(strlen(text)) AS chars,
       array_agg({'ts': timestamp, 'text': text} ORDER BY timestamp) AS said, len(said) AS prompts
FROM typed GROUP BY ALL ORDER BY first_ts;

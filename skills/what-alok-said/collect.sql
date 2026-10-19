-- Everything Alok typed to an agent in the last 14 days, one row per session, his prompts in order. stream.blocks
-- already parses every transcript and marks is_prompt (typed by a person, harness text excluded) and is_repeat.
WITH typed AS (
    SELECT source, session_id, timestamp, message_content AS text FROM stream.blocks
    WHERE is_prompt AND NOT is_repeat AND timestamp > now() - INTERVAL 14 DAY
)
SELECT source, session_id, array_agg({'ts': timestamp, 'text': text} ORDER BY timestamp) AS said,
       said[1].ts AS first_ts, said[-1].ts AS last_ts, len(said) AS prompts, sum(strlen(text)) AS chars
FROM typed GROUP BY ALL ORDER BY first_ts;

-- Do the hooks change what agents do? Four questions over agent.tool_call_analysis, one row per call:
-- agent.copies' first_seen keeps a call once when resumed or forked transcripts repeat it.
-- The rule is the first sentence of a hook's block message; next_* is the following call in the same transcript.

-- 1. What the next call is after each hook block.
WITH t AS (
    SELECT ts, tool, programs, string_split(string_split(error, 'BLOCKED by user hook: ')[2], '.')[1] AS rule,
           lead(tool) OVER w AS next_tool, lead(error) OVER w AS next_error,
           lead(string_split(string_split(error, 'BLOCKED by user hook: ')[2], '.')[1]) OVER w AS next_rule
    FROM agent.tool_call_analysis
    SEMI JOIN agent.copies ON copies.kind = 'tool_call' AND copies.first_seen AND copies.source = tool_call_analysis.source AND copies.id = call_id AND copies.file = transcript
    WHERE tool_call_analysis.source = 'claude' AND ts >= now() - INTERVAL 30 DAY
    WINDOW w AS (PARTITION BY session_id, transcript ORDER BY ts))
SELECT rule, count(ts) AS blocks, histogram(next_tool) AS next_tool,
       sum((next_rule IS NOT DISTINCT FROM rule)::INT) AS next_blocked_same_rule, sum((next_error IS NULL)::INT) AS next_succeeded
FROM t WHERE rule IS NOT NULL GROUP BY rule ORDER BY blocks DESC;

-- 2. The programs a blocked Bash call is retried with.
WITH t AS (
    SELECT tool, string_split(string_split(error, 'BLOCKED by user hook: ')[2], '.')[1] AS rule,
           lead(tool) OVER w AS next_tool, lead(programs) OVER w AS next_programs, lead(error) OVER w AS next_error
    FROM agent.tool_call_analysis
    SEMI JOIN agent.copies ON copies.kind = 'tool_call' AND copies.first_seen AND copies.source = tool_call_analysis.source AND copies.id = call_id AND copies.file = transcript
    WHERE tool_call_analysis.source = 'claude' AND ts >= now() - INTERVAL 30 DAY
    WINDOW w AS (PARTITION BY session_id, transcript ORDER BY ts))
SELECT rule, program, count(program) AS times, sum((next_error IS NULL)::INT) AS succeeded
FROM t CROSS JOIN UNNEST(next_programs) AS p(program) WHERE tool = 'Bash' AND next_tool = 'Bash' AND rule IS NOT NULL
GROUP BY ALL ORDER BY times DESC;

-- 3. Whether a session keeps hitting a rule it was already blocked by.
WITH b AS (
    SELECT session_id, ts, string_split(string_split(error, 'BLOCKED by user hook: ')[2], '.')[1] AS rule
    FROM agent.tool_call_analysis
    SEMI JOIN agent.copies ON copies.kind = 'tool_call' AND copies.first_seen AND copies.source = tool_call_analysis.source AND copies.id = call_id AND copies.file = transcript
    WHERE tool_call_analysis.source = 'claude' AND ts >= now() - INTERVAL 30 DAY AND contains(error, 'BLOCKED by user hook')),
per AS (SELECT rule, session_id, count(ts) AS blocks FROM b GROUP BY ALL)
SELECT rule, count(session_id) AS sessions, sum((blocks >= 3)::INT) AS sessions_3_plus, max(blocks) AS most_in_one_session
FROM per GROUP BY rule ORDER BY sessions_3_plus DESC;

-- 4. Whether loading a duckstack skill changes how much of a session goes through dev.
WITH s AS (
    SELECT session_id, bool_or(tool = 'Skill' AND starts_with(input ->> 'skill', 'duckstack:')) AS loaded_duck_skill,
           sum(starts_with(tool, 'mcp__dev__')::INT) AS dev, sum((tool = 'Bash')::INT) AS bash, sum((tool IN ('Read', 'Edit', 'Write'))::INT) AS native,
           sum(contains(error, 'BLOCKED by user hook')::INT) AS blocks, count(ts) AS calls
    FROM agent.tool_call_analysis
    SEMI JOIN agent.copies ON copies.kind = 'tool_call' AND copies.first_seen AND copies.source = tool_call_analysis.source AND copies.id = call_id AND copies.file = transcript
    WHERE tool_call_analysis.source = 'claude' AND ts >= now() - INTERVAL 30 DAY GROUP BY session_id)
SELECT loaded_duck_skill, count(session_id) AS sessions, sum(calls) AS calls,
       round(median(100.0 * dev / nullif(dev + bash + native, 0)), 1) AS median_dev_pct, round(median(100.0 * blocks / calls), 2) AS median_block_pct
FROM s WHERE calls >= 100 GROUP BY loaded_duck_skill;

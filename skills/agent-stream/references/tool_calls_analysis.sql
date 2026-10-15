-- Tool-call analysis: GROUP BYs over agent.tool_call_analysis (server/setup.sql; first copy of each call from
-- agent.tool_calls, plus programs/functions/error). Change the WHERE for another window or source.

-- Calls and errors per day and tool.
SELECT ts::DATE AS day, tool, count(tool) AS calls, count(error) AS errors
FROM agent.tool_call_analysisWHERE source = 'claude' AND ts >= now() - INTERVAL 30 DAY
GROUP BY ALL ORDER BY ALL;

-- Programs the calls ran: Bash commands and the commands inside shellfs pipes.
SELECT program, tool, count(program) AS calls, count(error) AS errors, count(DISTINCT session_id) AS sessions
FROM agent.tool_call_analysisCROSS JOIN UNNEST(programs) AS p(program) WHERE source = 'claude' AND ts >= now() - INTERVAL 30 DAY
GROUP BY ALL ORDER BY calls DESC;

-- Functions the SQL called.
SELECT function, count(function) AS calls, count(error) AS errors, count(DISTINCT session_id) AS sessions
FROM agent.tool_call_analysisCROSS JOIN UNNEST(functions) AS f(function) WHERE source = 'claude' AND ts >= now() - INTERVAL 30 DAY
GROUP BY ALL ORDER BY calls DESC;

-- Errors by tool and the error's first line.
SELECT tool, string_split(error, e'\n')[1] AS first_line, count(error) AS errors, count(DISTINCT session_id) AS sessions
FROM agent.tool_call_analysisWHERE source = 'claude' AND ts >= now() - INTERVAL 30 DAY AND error IS NOT NULL
GROUP BY ALL ORDER BY errors DESC;

-- Calls and errors per session and tool.
SELECT session_id, tool, count(tool) AS calls, count(error) AS errors, min(ts) AS first_call, max(ts) AS last_call
FROM agent.tool_call_analysisWHERE source = 'claude' AND ts >= now() - INTERVAL 30 DAY
GROUP BY ALL ORDER BY session_id, calls DESC;

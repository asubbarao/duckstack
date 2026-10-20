-- Which text fields of agent.lines repeat each other? For every pair, over one day: how often each is present, how
-- often both are, and how often they then agree. A pair that always agrees is one column:
-- coalesce(nullif(a, ''), nullif(b, '')) when each fills gaps in the other, or drop the one that is a subset.
-- 2026-10-20 (1 day): per_turn_effort = effort on all 11,439 shared lines (one column); source_tool_assistant_uuid
-- = parent_uuid on all 6,220 (dropped); requested_model = message.model on all 11,439 (message keeps it);
-- message.role = type on all 18,685. advisor_model agrees with requested_model only 97%, so both stay.
-- The field list is lines_columns.sql's VARCHAR group plus the raw_ field.
WITH typed_lines AS (
    FROM inflect('snake', (
        SELECT concat(transcript, ':', file_row_number) AS line_key,
               COLUMNS(['type', 'sessionId', 'version', 'cwd', 'entrypoint', 'gitBranch', 'userType', 'uuid', 'parentUuid', 'agentId', 'effort', 'perTurnEffort', 'requestId', 'requestedModel', 'advisorModel', 'slug', 'serverClassifierRequest', 'promptId', 'renderedRole', 'sourceToolAssistantUUID']) ->> '$',
               session_id ->> '$' AS raw_session_id
        FROM agent.lines WHERE (timestamp ->> '$')::TIMESTAMPTZ > now() - INTERVAL 1 DAY))
), long_values AS (
    SELECT line_key, column_name, value
    FROM (UNPIVOT typed_lines ON COLUMNS(* EXCLUDE (line_key)) INTO NAME column_name VALUE value)
    WHERE value <> ''
), present AS (
    SELECT column_name, len(list(line_key)) AS present_n FROM long_values GROUP BY column_name
), pairs AS (
    SELECT a.column_name AS column_a, b.column_name AS column_b, len(list(a.line_key)) AS both_n,
           len(list_filter(list(a.value = b.value), same -> same)) AS agree_n
    FROM long_values AS a JOIN long_values AS b ON a.line_key = b.line_key AND a.column_name < b.column_name
    GROUP BY ALL
)
SELECT column_a, column_b, pa.present_n AS a_n, pb.present_n AS b_n, both_n, agree_n,
       pa.present_n + pb.present_n - both_n AS coalesced_n
FROM pairs JOIN present AS pa ON pa.column_name = column_a JOIN present AS pb ON pb.column_name = column_b
WHERE agree_n > 0 AND agree_n >= 0.95 * both_n
ORDER BY agree_n DESC

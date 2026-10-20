-- agent.lines keeps every top-level transcript field as a JSON column (server/agent.sql reads with maximum_depth 1,
-- because one field can be a struct in one file and a MAP in another). That is the holding area: new fields land
-- there untouched, with JSON quotes on every string. This query is the gate that turns it into the columns
-- readers want, and prints the statement to paste where they are used:
--   1. SUMMARIZE the last 7 days; keep fields under 90% NULL (2026-10-20: 34 of 192).
--   2. One dispatched statement reads each kept field's JSON types (json_type) and TRY_CASTs strings to
--      TIMESTAMPTZ: one scalar type -> unwrap with ->> '$' and cast; objects, arrays or mixed types stay JSON.
--   3. One COLUMNS([...]) line per type; inflect('snake', ...) renames them all. When two fields map to one
--      snake_case name, the one already in snake_case is selected as raw_<name> (session_id vs sessionId).
--   4. DESCRIBE checks the result; `described` lists each column's type.
-- Then run lines_redundancy.sql for fields that repeat each other. Rerun both when new fields show up.
-- json_group_structure is not used: on message/payload it ran dev out of memory.
WITH column_stats AS (
    SELECT column_name, null_percentage::DOUBLE AS null_pct
    FROM (SUMMARIZE SELECT * FROM agent.lines WHERE (timestamp ->> '$')::TIMESTAMPTZ > now() - INTERVAL 7 DAY)
), gate AS (
    SELECT list(quote_literal(column_name)) AS kept_json_columns
    FROM column_stats WHERE null_pct < 90 AND column_name NOT IN ('transcript', 'file_row_number')
), type_atom AS (
    SELECT array_agg(selfdispatch(tera_render($t$WITH shapes AS (
    UNPIVOT (SELECT list(DISTINCT {'json_type': json_type(COLUMNS([{{ kept_json_columns | join(sep=", ") }}])),
                                   'is_timestamp': TRY_CAST(COLUMNS([{{ kept_json_columns | join(sep=", ") }}]) ->> '$' AS TIMESTAMPTZ) IS NOT NULL})
             FROM agent.lines WHERE (timestamp ->> '$')::TIMESTAMPTZ > now() - INTERVAL 7 DAY)
    ON COLUMNS(*) INTO NAME column_name VALUE shapes
), seen AS (
    SELECT column_name, list_filter(shapes, s -> s.json_type IS NOT NULL) AS seen FROM shapes
)
SELECT column_name, CASE WHEN len(seen) <> 1 THEN 'JSON' WHEN list_contains(['OBJECT', 'ARRAY'], seen[1].json_type) THEN 'JSON'
                         WHEN seen[1].is_timestamp THEN 'TIMESTAMPTZ' ELSE seen[1].json_type END AS target_type
FROM seen$t$, g::JSON, autoescape := false))) AS receipts
    FROM gate AS g
), typed AS (
    SELECT row ->> 'column_name' AS column_name, row ->> 'target_type' AS target_type
    FROM type_atom CROSS JOIN UNNEST(receipts) AS r(receipt) CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(row)
), named AS (
    SELECT typed.*, column_stats.null_pct,
           len(list(typed.column_name) OVER (PARTITION BY inflector_to_snake_case(typed.column_name))) > 1
               AND typed.column_name = inflector_to_snake_case(typed.column_name) AS renamed_raw
    FROM typed JOIN column_stats USING (column_name)
), type_groups AS (
    SELECT target_type, min(null_pct) AS first_null_pct,
           tera_render(CASE target_type WHEN 'JSON' THEN 'COLUMNS([{{ names | join(sep=", ") }}])'
                                        WHEN 'VARCHAR' THEN 'COLUMNS([{{ names | join(sep=", ") }}]) ->> ''$'''
                                        ELSE '(COLUMNS([{{ names | join(sep=", ") }}]) ->> ''$'')::{{ target_type }}' END,
                       {'names': list(quote_literal(column_name) ORDER BY null_pct, column_name), 'target_type': target_type}::JSON, autoescape := false) AS expression
    FROM named WHERE NOT renamed_raw GROUP BY target_type
    UNION ALL
    SELECT target_type, null_pct, tera_render('{{ name }} ->> ''$'' AS raw_{{ name }}', {'name': column_name}::JSON, autoescape := false)
    FROM named WHERE renamed_raw
    UNION ALL
    SELECT 'READER', 100, 'transcript, file_row_number'
), rendered AS (
    SELECT tera_render($t$FROM inflect('snake', (
    SELECT {{ lines | join(sep=",
           ") }}
    FROM agent.lines))$t$, {'lines': list(expression ORDER BY first_null_pct, target_type)}::JSON, autoescape := false) AS lines_sql
    FROM type_groups
), describe_atom AS (
    SELECT lines_sql, array_agg(selfdispatch(concat('DESCRIBE ', lines_sql))) AS receipts FROM rendered GROUP BY lines_sql
)
SELECT lines_sql, len(list(row ->> 'column_name')) AS columns, list(concat(row ->> 'column_name', ' ', row ->> 'column_type')) AS described
FROM describe_atom CROSS JOIN UNNEST(receipts) AS r(receipt) CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(row)
GROUP BY lines_sql

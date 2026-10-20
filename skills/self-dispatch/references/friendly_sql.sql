-- Friendly SQL we lean on, read from DuckDB's own pages, and how often agents use it. Run each query on dev.
--
-- 1. The features each page documents: its inline `code` spans, in page order, one row per page. web_page() takes
--    one literal URL, so each page is its own dispatched statement.
WITH pages AS (
  SELECT unnest(['https://duckdb.org/docs/current/sql/query_syntax/select',
                 'https://duckdb.org/2023/08/23/even-friendlier-sql',
                 'https://duckdb.org/docs/current/sql/dialect/friendly_sql',
                 'https://duckdb.org/docs/lts/sql/statements/pivot',
                 'https://duckdb.org/docs/lts/sql/statements/unpivot']) AS url),
page_statements AS (
  SELECT url, tera_render($t$SELECT status, list_distinct(array_agg(b.content ORDER BY b.element_order)) AS features
FROM web_page('{{ url }}') CROSS JOIN UNNEST(duckblocks) AS block(b)
WHERE b.kind = 'inline' AND b.element_type = 'code' GROUP BY status$t$, json_object('url', url), autoescape := false) AS executable_sql
  FROM pages),
dispatched AS (
  SELECT url, executable_sql, array_agg(selfdispatch(executable_sql)) AS receipts FROM page_statements GROUP BY ALL)
SELECT dispatched.url, dispatch.receipt.status AS post_status, dispatch.receipt.error,
       page.row ->> 'status' AS page_status, (page.row -> 'features')::VARCHAR[] AS features
FROM dispatched
CROSS JOIN UNNEST(receipts) AS dispatch(receipt)
CROSS JOIN UNNEST(TRY_CAST(dispatch.receipt.body AS JSON[])) AS page(row);

-- 2. How many SQL tool calls in the last 7 days use each feature, read from each call's AST (json_serialize_sql
--    takes SELECT-shaped statements; COPY, CREATE and a bare PIVOT statement are not counted).
WITH sql_calls AS (
  SELECT tool_use_id, coalesce(tool_input ->> 'sql', tool_input ->> 'statement') AS sql_text
  FROM stream.blocks
  WHERE block_type = 'tool_use' AND NOT is_repeat AND contains(tool_name, '__query') AND timestamp > now() - INTERVAL 7 DAY),
parsed AS (
  SELECT *, json_serialize_sql(sql_text, skip_null := true, skip_empty := true, skip_default := true) AS ast FROM sql_calls),
features AS (
  SELECT p.tool_use_id,
         CASE WHEN (node.value ->> 'aggregate_handling') = 'FORCE_AGGREGATES' THEN 'GROUP BY ALL'
              WHEN (node.value ->> 'columns') = 'true' THEN 'COLUMNS(...)'
              WHEN (node.value -> 'exclude_list') IS NOT NULL THEN '* EXCLUDE'
              WHEN (node.value -> 'replace_list') IS NOT NULL THEN '* REPLACE'
              WHEN (node.value -> 'rename_list') IS NOT NULL THEN '* RENAME'
              WHEN (node.value ->> 'show_type') = 'SUMMARY' THEN 'SUMMARIZE'
              WHEN (node.value ->> 'show_type') = 'DESCRIBE' THEN 'DESCRIBE'
              WHEN (node.value ->> 'type') = 'PIVOT' THEN CASE WHEN (node.value -> 'unpivot_names') IS NULL THEN 'PIVOT' ELSE 'UNPIVOT' END
              WHEN (node.value ->> 'type') = 'LIMIT_PERCENT_MODIFIER' THEN 'LIMIT n%'
              WHEN (node.value ->> 'setop_type') = 'UNION_BY_NAME' THEN 'UNION BY NAME'
              WHEN (node.value -> 'qualify') IS NOT NULL THEN 'QUALIFY'
              WHEN (node.value ->> 'type') = 'ARRAY_EXTRACT' AND (node.value -> 'children' -> 0 ->> 'function_name') IN ('string_split', 'str_split', 'split', 'string_split_regex', 'str_split_regex', 'regexp_split_to_array') THEN 'string_split(...)[n]'
              WHEN (node.value ->> 'function_name') IN ('max', 'min') AND json_array_length(node.value -> 'children') = 2 THEN 'top-n max(v, n) / arg_max(x, v, n)'
              WHEN (node.value ->> 'function_name') IN ('arg_max', 'arg_min', 'max_by', 'min_by') AND json_array_length(node.value -> 'children') = 3 THEN 'top-n max(v, n) / arg_max(x, v, n)'
              WHEN (node.value ->> 'function_name') IN ('json_extract', 'json_extract_string', 'json_extract_path', 'json_extract_path_text') THEN 'json_extract'
              WHEN (node.value ->> 'function_name') IN ('any_value', 'arbitrary') THEN 'any_value' END AS feature
  FROM parsed AS p CROSS JOIN LATERAL json_tree(p.ast) AS node
  WHERE (p.ast ->> 'error') = 'false' AND node.type = 'OBJECT')
SELECT feature, len(array_agg(DISTINCT tool_use_id)) AS calls FROM features WHERE feature IS NOT NULL GROUP BY feature
UNION ALL
SELECT '(SQL tool calls)', count(tool_use_id) FROM parsed
UNION ALL
SELECT '(calls with an AST)', count(CASE WHEN (ast ->> 'error') = 'false' THEN tool_use_id END) FROM parsed
ORDER BY calls DESC;

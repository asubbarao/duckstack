-- Friendly SQL we lean on, read from DuckDB's own pages, and how often agents use it. Run each query on dev.
--
-- 1. The features each page documents: its inline `code` spans, in page order, one row per page. Each page is
--    fetched by curl through shellfs and parsed by webbed's html_to_duck_blocks, one dispatched statement per page;
--    --fail turns a missing page into a receipt error, never rows.
WITH pages AS (
  SELECT unnest(['https://duckdb.org/docs/current/sql/query_syntax/select',
                 'https://duckdb.org/2023/08/23/even-friendlier-sql',
                 'https://duckdb.org/docs/current/sql/dialect/friendly_sql',
                 'https://duckdb.org/docs/lts/sql/statements/pivot',
                 'https://duckdb.org/docs/lts/sql/statements/unpivot']) AS url),
page_statements AS (
  SELECT url, tera_render($t$SELECT list_distinct(array_agg(b.content ORDER BY b.element_order)) AS features
FROM read_text('curl -sSL --fail --max-time 30 {{ url }} |')
CROSS JOIN UNNEST(html_to_duck_blocks(content::HTML)) AS block(b)
WHERE b.kind = 'inline' AND b.element_type = 'code'$t$, p::JSON, autoescape := false) AS executable_sql
  FROM pages AS p),
dispatched AS (
  SELECT url, executable_sql, array_agg(selfdispatch(executable_sql)) AS receipts FROM page_statements GROUP BY ALL)
SELECT dispatched.url, dispatch.receipt.status AS post_status, dispatch.receipt.error,
       (page.row -> 'features')::VARCHAR[] AS features
FROM dispatched
CROSS JOIN UNNEST(receipts) AS dispatch(receipt)
CROSS JOIN UNNEST(TRY_CAST(dispatch.receipt.body AS JSON[])) AS page(row);

-- 2. How many SQL tool calls in the last 7 days use each feature, read from each call's AST (json_serialize_sql
--    takes SELECT-shaped statements; COPY, CREATE and a bare PIVOT statement are not counted). Each feature is a
--    marker row: an AST field with a value, a field that is present, or a function (by arity, or indexed by [n]).
WITH value_markers AS (SELECT unnest([
  {'feature': 'GROUP BY ALL', 'field': 'aggregate_handling', 'value': 'FORCE_AGGREGATES'},
  {'feature': 'COLUMNS(...)', 'field': 'columns', 'value': 'true'},
  {'feature': 'SUMMARIZE', 'field': 'show_type', 'value': 'SUMMARY'},
  {'feature': 'DESCRIBE', 'field': 'show_type', 'value': 'DESCRIBE'},
  {'feature': 'LIMIT n%', 'field': 'type', 'value': 'LIMIT_PERCENT_MODIFIER'},
  {'feature': 'UNION BY NAME', 'field': 'setop_type', 'value': 'UNION_BY_NAME'}], recursive := true)),
key_markers AS (SELECT unnest([
  {'feature': '* EXCLUDE', 'field': 'exclude_list'}, {'feature': '* REPLACE', 'field': 'replace_list'},
  {'feature': '* RENAME', 'field': 'rename_list'}, {'feature': 'QUALIFY', 'field': 'qualify'},
  {'feature': 'PIVOT', 'field': 'aggregates'}, {'feature': 'UNPIVOT', 'field': 'unpivot_names'}], recursive := true)),
function_markers AS (SELECT unnest([
  {'feature': 'top-n max(v, n) / arg_max(x, v, n)', 'functions': ['max', 'min'], 'arity': 2, 'indexed': false},
  {'feature': 'top-n max(v, n) / arg_max(x, v, n)', 'functions': ['arg_max', 'arg_min', 'max_by', 'min_by'], 'arity': 3, 'indexed': false},
  {'feature': 'json_extract', 'functions': ['json_extract', 'json_extract_string', 'json_extract_path', 'json_extract_path_text'], 'arity': NULL, 'indexed': false},
  {'feature': 'any_value', 'functions': ['any_value', 'arbitrary'], 'arity': NULL, 'indexed': false},
  {'feature': 'string_split(...)[n]', 'functions': ['string_split', 'str_split', 'split', 'string_split_regex', 'str_split_regex', 'regexp_split_to_array'], 'arity': NULL, 'indexed': true}], recursive := true)),
sql_calls AS (
  SELECT tool_use_id, coalesce(tool_input ->> 'sql', tool_input ->> 'statement') AS sql_text
  FROM stream.blocks
  WHERE block_type = 'tool_use' AND NOT is_repeat AND contains(tool_name, '__query') AND timestamp > now() - INTERVAL 7 DAY),
parsed AS (
  SELECT *, json_serialize_sql(sql_text, skip_null := true, skip_empty := true, skip_default := true) AS ast FROM sql_calls),
nodes AS (
  SELECT p.tool_use_id, node.key, node.value ->> '$' AS scalar, node.value ->> 'function_name' AS function_name,
         json_array_length(node.value -> 'children') AS n_args,
         CASE WHEN (node.value ->> 'type') = 'ARRAY_EXTRACT' THEN node.value -> 'children' -> 0 ->> 'function_name' END AS indexed_function
  FROM parsed AS p CROSS JOIN LATERAL json_tree(p.ast) AS node
  WHERE (p.ast ->> 'error') = 'false'),
hits AS (
  SELECT m.feature, n.tool_use_id FROM nodes AS n JOIN value_markers AS m ON (n.key, n.scalar) = (m.field, m.value)
  UNION ALL
  SELECT m.feature, n.tool_use_id FROM nodes AS n JOIN key_markers AS m ON n.key = m.field
  UNION ALL
  SELECT m.feature, n.tool_use_id FROM nodes AS n JOIN function_markers AS m
    ON list_contains(m.functions, CASE WHEN m.indexed THEN n.indexed_function ELSE n.function_name END)
   AND coalesce(m.arity, n.n_args) = n.n_args)
SELECT feature, len(array_agg(DISTINCT tool_use_id)) AS calls FROM hits GROUP BY feature
UNION ALL
SELECT '(SQL tool calls)', count(tool_use_id) FROM parsed
UNION ALL
SELECT '(calls with an AST)', count(CASE WHEN (ast ->> 'error') = 'false' THEN tool_use_id END) FROM parsed
ORDER BY calls DESC;

-- Friendly SQL we lean on, read from DuckDB's own pages, and how often agents use it. Run each query on dev.
--
-- 1. The features each page documents: its inline `code` spans, in page order, one row per page. Each page is
--    fetched by curl through shellfs and parsed by webbed's html_to_duck_blocks, one dispatched statement per page;
--    --fail turns a missing page into its row with the receipt error and no features.
WITH pages AS (
  -- docs/current and docs/lts answer with a meta-refresh page (2026-10-21), so the docs pages are the versioned ones.
  SELECT unnest(['https://duckdb.org/docs/2.0/sql/query_syntax/select.html',
                 'https://duckdb.org/2023/08/23/even-friendlier-sql',
                 'https://duckdb.org/docs/2.0/sql/dialect/friendly_sql.html',
                 'https://duckdb.org/docs/2.0/sql/statements/pivot.html',
                 'https://duckdb.org/docs/2.0/sql/statements/unpivot.html']) AS url),
page_statements AS (
  SELECT url, tera_render($t$SELECT array_agg(content ORDER BY first_seen) AS features
FROM (SELECT b.content, min(b.element_order) AS first_seen
      FROM read_text('curl -sSL --fail --max-time 30 {{ url }} |')
      CROSS JOIN UNNEST(html_to_duck_blocks(content::HTML)) AS block(b)
      WHERE b.kind = 'inline' AND b.element_type = 'code' AND b.content IS NOT NULL
      GROUP BY b.content)$t$, p::JSON, autoescape := false) AS executable_sql
  FROM pages AS p),
dispatched AS (
  SELECT url, executable_sql, array_agg(selfdispatch(executable_sql)) AS receipts FROM page_statements GROUP BY ALL)
SELECT dispatched.url, dispatch.receipt.status AS post_status, dispatch.receipt.error,
       (TRY_CAST(dispatch.receipt.body AS JSON[])[1] -> 'features')::VARCHAR[] AS features
FROM dispatched
CROSS JOIN UNNEST(receipts) AS dispatch(receipt);

-- 2. How many SQL tool calls in the last 7 days use each feature, read from each call's AST (json_serialize_sql
--    takes SELECT-shaped statements; COPY, CREATE and a bare PIVOT statement are not counted). Each feature is a
--    marker row: an AST field with a value, a field that is present (no value), or a function (by arity, or indexed by [n]).
WITH field_markers AS (SELECT unnest([
  {'feature': 'GROUP BY ALL', 'field': 'aggregate_handling', 'value': 'FORCE_AGGREGATES'},
  {'feature': 'COLUMNS(...)', 'field': 'columns', 'value': 'true'},
  {'feature': 'SUMMARIZE', 'field': 'show_type', 'value': 'SUMMARY'},
  {'feature': 'DESCRIBE', 'field': 'show_type', 'value': 'DESCRIBE'},
  {'feature': 'LIMIT n%', 'field': 'type', 'value': 'LIMIT_PERCENT_MODIFIER'},
  {'feature': 'UNION BY NAME', 'field': 'setop_type', 'value': 'UNION_BY_NAME'},
  {'feature': '* EXCLUDE', 'field': 'exclude_list', 'value': NULL}, {'feature': '* REPLACE', 'field': 'replace_list', 'value': NULL},
  {'feature': '* RENAME', 'field': 'rename_list', 'value': NULL}, {'feature': 'QUALIFY', 'field': 'qualify', 'value': NULL},
  {'feature': 'PIVOT', 'field': 'aggregates', 'value': NULL}, {'feature': 'UNPIVOT', 'field': 'unpivot_names', 'value': NULL}], recursive := true)),
function_markers AS (SELECT unnest([
  {'feature': 'top-n max(v, n) / arg_max(x, v, n)', 'functions': ['max', 'min'], 'arity': 2, 'indexed': false},
  {'feature': 'top-n max(v, n) / arg_max(x, v, n)', 'functions': ['arg_max', 'arg_min', 'max_by', 'min_by'], 'arity': 3, 'indexed': false},
  {'feature': 'json_extract', 'functions': ['json_extract', 'json_extract_string', 'json_extract_path', 'json_extract_path_text'], 'arity': NULL, 'indexed': false},
  {'feature': 'any_value', 'functions': ['any_value', 'arbitrary'], 'arity': NULL, 'indexed': false},
  {'feature': 'string_split(...)[n]', 'functions': ['string_split', 'str_split', 'split', 'string_split_regex', 'str_split_regex', 'regexp_split_to_array'], 'arity': NULL, 'indexed': true}], recursive := true)),
sql_calls AS (
  -- stream.blocks' tool_command is the call's sql or statement (server/blocks.sql).
  SELECT tool_use_id, tool_command AS sql_text
  FROM stream.blocks
  WHERE block_type = 'tool_use' AND NOT is_repeat AND timestamp > now() - INTERVAL 7 DAY
    AND tool_name IN ('mcp__dev__query', 'mcp__dev__query_full', 'mcp__dev__execute', 'mcp__duck__query', 'mcp__duck__execute')),
parsed AS (
  SELECT *, json_serialize_sql(sql_text, skip_null := true, skip_empty := true, skip_default := true) AS ast FROM sql_calls),
nodes AS (
  SELECT p.tool_use_id, node.key, node.value ->> '$' AS scalar, node.value ->> 'function_name' AS function_name,
         (node.value -> 'children')::JSON[] AS children, len(children) AS n_args,
         CASE WHEN (node.value ->> 'type') = 'ARRAY_EXTRACT' THEN children[1] ->> 'function_name' END AS indexed_function
  FROM parsed AS p CROSS JOIN LATERAL json_tree(p.ast) AS node
  WHERE (p.ast ->> 'error') = 'false'),
hits AS (
  SELECT m.feature, n.tool_use_id FROM nodes AS n JOIN field_markers AS m
    ON n.key = m.field AND n.scalar IS NOT DISTINCT FROM coalesce(m.value, n.scalar)
  UNION ALL
  SELECT m.feature, n.tool_use_id FROM nodes AS n JOIN function_markers AS m
    ON list_contains(m.functions, CASE WHEN m.indexed THEN n.indexed_function ELSE n.function_name END)
   AND coalesce(m.arity, n.n_args) = n.n_args
  UNION ALL
  SELECT '(SQL tool calls)', tool_use_id FROM parsed
  UNION ALL
  SELECT '(calls with an AST)', tool_use_id FROM parsed WHERE (ast ->> 'error') = 'false')
SELECT feature, len(array_agg(DISTINCT tool_use_id)) AS calls FROM hits GROUP BY feature ORDER BY calls DESC;

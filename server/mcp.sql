CREATE OR REPLACE MIDDLEWARE mcp BEFORE GROUP mcp AS
-- MCP owns preview policy; /sql and execute continue to run the posted SQL unchanged.
-- PWD is the launch checkout, even after branches.sql changes DuckDB's working directory.
WITH msg AS (
    SELECT policy, body -> '$.id' AS id, body ->> '$.method' AS method, body ->> '$.params.name' AS tool_name,
           MAP {'query': 'sql', 'query_full': 'sql', 'execute': 'statement'}[tool_name] AS argument_key,
           body -> '$.params.arguments' -> argument_key AS argument,
           argument ->> '$' AS sql,
           json_type(argument) IS NOT DISTINCT FROM 'VARCHAR' AS valid_call
    FROM (SELECT $body::JSON AS body, {row_limit: 50, byte_limit: 8192, reserved_bytes: 256} AS policy)
), statements AS (
    SELECT *, CASE WHEN tool_name = 'query'
                   THEN tera_render('query_preview.tera', struct_insert(policy, sql := quote_literal(sql))::JSON, autoescape := false,
                                    template_path := concat(getenv('PWD'), '/server/*.tera'))
                   ELSE sql END AS executable_sql
    FROM msg WHERE method = 'tools/call' AND valid_call
), posted AS (
    SELECT id, method, tool_name, policy, array_agg({executable_sql: executable_sql, receipt: selfdispatch(executable_sql)}) AS receipts
    FROM statements GROUP BY id, method, tool_name, policy
), called AS (
    SELECT id, method, tool_name FROM msg WHERE method IS DISTINCT FROM 'tools/call'
    UNION ALL BY NAME
    SELECT id, method, tool_name, json_object('detail', 'Unknown tool or missing string SQL argument') AS reply, true AS failed
    FROM msg WHERE method = 'tools/call' AND NOT valid_call
    UNION ALL BY NAME
    SELECT id, method, tool_name,
           coalesce(CASE WHEN tool_name = 'query' AND sent.receipt.status = 200
                         THEN try_cast(sent.receipt.body::JSON ->> '$[0].preview' AS JSON)
                         ELSE try_cast(sent.receipt.body AS JSON) END,
                    json_object('detail', coalesce(sent.receipt.error, sent.receipt.body))) AS answer,
           CASE WHEN sent.receipt.status = 200 THEN json_exists(answer, '$.detail') ELSE true END AS failed,
           CASE WHEN tool_name = 'query' AND failed AND strlen(answer::VARCHAR) > policy.byte_limit
                THEN json_object('detail', left(answer::VARCHAR, 512), 'truncated', true, 'reason', 'byte_limit')
                ELSE answer END AS reply
    FROM posted CROSS JOIN UNNEST(receipts) AS t(sent)
)
SELECT false AS allow, CASE WHEN id IS NULL THEN 202 ELSE 200 END AS status,
       json_object('jsonrpc', '2.0', 'id', id, 'result', coalesce(
           MAP {'initialize': '{"protocolVersion": "2025-06-18", "serverInfo": {"name": "dev", "version": "2"}, "capabilities": {"tools": {}}}',
                'ping': '{}',
                'tools/list': '{"tools": [{"name": "query", "description": "Preview one SELECT on dev: at most 50 complete rows and 8 KiB of result text, with returned_rows, truncated and reason. Preserves SQL ordering; use ORDER BY for a meaningful prefix. Use query_full for complete results and execute for COPY or writes.", "inputSchema": {"type": "object", "properties": {"sql": {"type": "string"}}, "required": ["sql"]}}, {"name": "query_full", "description": "Run SQL on dev and return the complete result without preview row or byte limits. Large replies consume context; prefer query for exploration. Transport and query timeout limits still apply.", "inputSchema": {"type": "object", "properties": {"sql": {"type": "string"}}, "required": ["sql"]}}, {"name": "execute", "description": "Run SQL unchanged on dev, including COPY, DDL and writes. No preview limits apply to the operation or its result.", "inputSchema": {"type": "object", "properties": {"statement": {"type": "string"}}, "required": ["statement"]}}]}' }[method]::JSON,
           json_object('content', [json_object('type', 'text', 'text', reply::VARCHAR)], 'isError', failed)))::VARCHAR AS body,
       NULL::VARCHAR AS header_name, NULL::VARCHAR AS header_value
FROM called;


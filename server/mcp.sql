CREATE OR REPLACE MIDDLEWARE mcp BEFORE GROUP mcp AS
-- Every tool posts its SQL to /sql unchanged; query caps only the reply, keeping a prefix of complete rows.
-- Dev still builds the whole result before the cut, so total_rows is exact.
WITH msg AS (
    SELECT policy, body -> '$.id' AS id, body ->> '$.method' AS method, body ->> '$.params.name' AS tool_name,
           MAP {'query': 'sql', 'query_full': 'sql', 'execute': 'statement'}[tool_name] AS argument_key,
           body -> '$.params.arguments' -> argument_key AS argument,
           argument ->> '$' AS sql,
           json_type(argument) IS NOT DISTINCT FROM 'VARCHAR' AS valid_call
    FROM (SELECT $body::JSON AS body, {row_limit: 50, byte_limit: 8192, reserved_bytes: 256} AS policy)
), posted AS (
    SELECT id, method, tool_name, policy, array_agg({sql: sql, receipt: selfdispatch(sql)}) AS receipts
    FROM msg WHERE method = 'tools/call' AND valid_call GROUP BY id, method, tool_name, policy
), received AS (
    -- used_bytes[i] is the text of rows 1..i as a JSON array; reserved_bytes leaves room for the metadata.
    SELECT id, method, tool_name, policy,
           coalesce(try_cast(sent.receipt.body AS JSON), json_object('detail', coalesce(sent.receipt.error, sent.receipt.body))) AS answer,
           CASE WHEN sent.receipt.status = 200 THEN json_exists(answer, '$.detail') ELSE true END AS failed,
           CASE WHEN tool_name = 'query' THEN answer -> '$[*]' END AS all_rows,
           all_rows[1:policy.row_limit] AS head,
           list_transform(head, lambda r: strlen(r::VARCHAR) + 1) AS sizes,
           list_transform(sizes, lambda s, i: 1 + list_sum(sizes[1:i])) AS used_bytes
    FROM posted CROSS JOIN UNNEST(receipts) AS t(sent)
), capped AS (
    SELECT id, method, tool_name, failed,
           len(list_filter(used_bytes, lambda u: u <= policy.byte_limit - policy.reserved_bytes)) AS returned_rows,
           len(all_rows) AS total_rows,
           returned_rows < total_rows AS truncated,
           CASE WHEN NOT truncated THEN NULL
                WHEN returned_rows = 0 THEN 'oversized_row'
                WHEN returned_rows < policy.row_limit THEN 'byte_limit'
                ELSE 'row_limit' END AS reason,
           CASE WHEN tool_name IS DISTINCT FROM 'query' THEN answer
                WHEN NOT failed THEN to_json({rows: head[1:returned_rows], returned_rows: returned_rows, total_rows: total_rows,
                                              truncated: truncated, reason: reason,
                                              row_limit: policy.row_limit, byte_limit: policy.byte_limit})
                WHEN strlen(answer::VARCHAR) > policy.byte_limit
                THEN json_object('detail', left(answer::VARCHAR, 512), 'truncated', true, 'reason', 'byte_limit')
                ELSE answer END AS reply
    FROM received
), called AS (
    SELECT id, method, tool_name FROM msg WHERE method IS DISTINCT FROM 'tools/call'
    UNION ALL BY NAME
    SELECT id, method, tool_name, json_object('detail', 'Unknown tool or missing string SQL argument') AS reply, true AS failed
    FROM msg WHERE method = 'tools/call' AND NOT valid_call
    UNION ALL BY NAME
    SELECT id, method, tool_name, reply, failed FROM capped
)
SELECT false AS allow, CASE WHEN id IS NULL THEN 202 ELSE 200 END AS status,
       json_object('jsonrpc', '2.0', 'id', id, 'result', coalesce(
           MAP {'initialize': '{"protocolVersion": "2025-06-18", "serverInfo": {"name": "dev", "version": "2"}, "capabilities": {"tools": {}}}',
                'ping': '{}',
                'tools/list': '{"tools": [{"name": "query", "description": "Run any SQL on dev unchanged (SELECT, PIVOT, LOAD, several statements, DDL) and cap the reply at 50 complete rows and 8 KiB: {rows, returned_rows, total_rows, truncated, reason, row_limit, byte_limit}. Dev still runs the whole statement; ORDER BY makes the prefix meaningful. Use query_full for the complete result.", "inputSchema": {"type": "object", "properties": {"sql": {"type": "string"}}, "required": ["sql"]}}, {"name": "query_full", "description": "Run any SQL on dev unchanged and return the complete result with no row or byte cap. Large replies consume context; prefer query to explore.", "inputSchema": {"type": "object", "properties": {"sql": {"type": "string"}}, "required": ["sql"]}}, {"name": "execute", "description": "Run any SQL on dev unchanged, including COPY, DDL and writes, and return the complete result with no row or byte cap, as query_full does.", "inputSchema": {"type": "object", "properties": {"statement": {"type": "string"}}, "required": ["statement"]}}]}' }[method]::JSON,
           json_object('content', [json_object('type', 'text', 'text', reply::VARCHAR)], 'isError', failed)))::VARCHAR AS body,
       NULL::VARCHAR AS header_name, NULL::VARCHAR AS header_value
FROM called;

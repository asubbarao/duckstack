CREATE OR REPLACE MIDDLEWARE mcp BEFORE GROUP mcp AS
-- MCP owns preview policy; /sql and execute continue to run the posted SQL unchanged.
-- PWD is the launch checkout, even after branches.sql changes DuckDB's working directory.
WITH msg AS (
    SELECT $body::JSON -> '$.id' AS id, $body::JSON ->> '$.method' AS method,
           $body::JSON ->> '$.params.name' AS tool_name,
           CASE tool_name WHEN 'execute' THEN $body::JSON -> '$.params.arguments.statement'
                ELSE $body::JSON -> '$.params.arguments.sql' END AS argument,
           argument ->> '$' AS sql,
           coalesce(tool_name IN ('query', 'query_full', 'execute') AND json_type(argument) = 'VARCHAR', false) AS valid_call
), statements AS (
    SELECT *, CASE WHEN tool_name = 'query'
                   THEN tera_render('query_preview.tera', json_object('sql', quote_literal(sql)), autoescape := false,
                                    template_path := concat(getenv('PWD'), '/server/*.tera'))
                   ELSE sql END AS executable_sql
    FROM msg WHERE method = 'tools/call' AND valid_call
), posted AS (
    SELECT id, method, tool_name, array_agg({executable_sql: executable_sql, receipt: selfdispatch(executable_sql)}) AS receipts
    FROM statements GROUP BY id, method, tool_name
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
                    json_object('detail', coalesce(sent.receipt.error, sent.receipt.body))) AS reply,
           CASE WHEN sent.receipt.status = 200 THEN coalesce(json_exists(reply, '$.detail'), false) ELSE true END AS failed
    FROM posted CROSS JOIN UNNEST(receipts) AS t(sent)
), replies AS (
    SELECT id, method, failed,
           CASE WHEN tool_name = 'query' AND failed AND strlen(reply::VARCHAR) > 8192
                THEN json_object('detail', left(reply::VARCHAR, 512), 'truncated', true, 'reason', 'byte_limit')
                ELSE reply END AS reply
    FROM called
)
SELECT false AS allow, CASE WHEN id IS NULL THEN 202 ELSE 200 END AS status,
       json_object('jsonrpc', '2.0', 'id', id, 'result', coalesce(
           MAP {'initialize': '{"protocolVersion": "2025-06-18", "serverInfo": {"name": "dev", "version": "2"}, "capabilities": {"tools": {}}}',
                'ping': '{}',
                'tools/list': '{"tools": [{"name": "query", "description": "Preview one SELECT on dev: at most 50 complete rows and 8 KiB of result text, with returned_rows, truncated and reason. Preserves SQL ordering; use ORDER BY for a meaningful prefix. Use query_full for complete results and execute for COPY or writes.", "inputSchema": {"type": "object", "properties": {"sql": {"type": "string"}}, "required": ["sql"]}}, {"name": "query_full", "description": "Run SQL on dev and return the complete result without preview row or byte limits. Large replies consume context; prefer query for exploration. Transport and query timeout limits still apply.", "inputSchema": {"type": "object", "properties": {"sql": {"type": "string"}}, "required": ["sql"]}}, {"name": "execute", "description": "Run SQL unchanged on dev, including COPY, DDL and writes. No preview limits apply to the operation or its result.", "inputSchema": {"type": "object", "properties": {"statement": {"type": "string"}}, "required": ["statement"]}}]}' }[method]::JSON,
           json_object('content', [json_object('type', 'text', 'text', reply::VARCHAR)], 'isError', failed)))::VARCHAR AS body,
       NULL::VARCHAR AS header_name, NULL::VARCHAR AS header_value
FROM replies;


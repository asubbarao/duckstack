-- Dev DuckDB. launchd runs `duckdb -bail ~/.duck/db/dev.duckdb -init setup.sql` and keeps stdin open.
-- Dev boots ~/.duck/deploy/server/setup.sql, the duckdb-skills branch `deploy`. A save here changes nothing until
-- it is committed and the branch moved: git branch -f deploy <commit>; the watcher restarts dev within 30 s.
-- The rest is read from server/*.sql, one concern per file, relative to the checkout root: the launchd wrapper starts
-- DuckDB in ~/.duck/deploy and CI in its checkout (.read expands no ~). branches.sql moves into ~/inframe, so it is last.
SET GLOBAL extension_directory = '~/.duck/extensions';
SET GLOBAL secret_directory = '~/.duck/secrets';
SET GLOBAL temp_directory = '~/.duck/tmp';
-- DuckDB's performance guide: 1-4 GB per thread. 10 threads x 1.6 GB; RSS runs 1.5-2.5 GB above this
-- (reader/JSON allocations are untracked), and the 48 GB machine keeps ~30 GB for everything else.
SET GLOBAL memory_limit = '16GB';
SET GLOBAL threads = 10;
SET GLOBAL TimeZone = 'UTC';
SET GLOBAL http_retries = 0;

-- INSTALL is a no-op once a file exists, so without this every boot reloads the first build ever downloaded.
-- A child process updates the files before anything below loads them; offline, it prints the error and boot goes on.
INSTALL shellfs FROM community; LOAD shellfs;
SELECT content FROM read_text($u$/opt/homebrew/bin/duckdb -csv :memory: -c "SET extension_directory = '~/.duck/extensions'; UPDATE EXTENSIONS;" 2>&1; true |$u$);
INSTALL quack; LOAD quack;
INSTALL httpfs; LOAD httpfs;
INSTALL ducklake; LOAD ducklake;
INSTALL cronjob FROM community; LOAD cronjob;
INSTALL hostfs FROM community; LOAD hostfs;
INSTALL http_client FROM community; LOAD http_client;
INSTALL read_lines FROM community; LOAD read_lines;
INSTALL agent_data FROM community; LOAD agent_data;
INSTALL quackapi FROM community; LOAD quackapi;
-- Used by the agents.ext_* docs views.
INSTALL webbed FROM community; LOAD webbed;
INSTALL markdown FROM community; LOAD markdown;
INSTALL urlpattern FROM community; LOAD urlpattern;
INSTALL otlp FROM community; LOAD otlp;
-- sazgar is intentionally not installed: community-extensions has no
-- linux_amd64 build published for DuckDB 1.5.5 (HTTP 404 on a fresh home),
-- and nothing in this boot uses it since the prometheus view was dropped.
-- Called by name from the skills (tera, duck-tails, duck-hunt, pdf-digest, ci-timing, ...).
INSTALL tera FROM community; LOAD tera;
INSTALL jsonata FROM community; LOAD jsonata;
INSTALL parser_tools FROM community; LOAD parser_tools;
INSTALL sitting_duck FROM community; LOAD sitting_duck;
INSTALL duck_tails FROM community; LOAD duck_tails;
INSTALL duck_hunt FROM community; LOAD duck_hunt;
INSTALL zipfs FROM community; LOAD zipfs;
INSTALL scalarfs FROM community; LOAD scalarfs;
INSTALL yaml FROM community; LOAD yaml;
INSTALL pdf FROM community; LOAD pdf;
INSTALL gh FROM community; LOAD gh;
INSTALL netquack FROM community; LOAD netquack;
INSTALL fts; LOAD fts;
CALL enable_logging(['QueryLog', 'HTTP', 'Quack', 'Metrics'], storage := 'file', storage_path := getenv('QUACK_NATIVE_LOG'), storage_buffer_size := 0);
.read server/profile.sql
.read server/docs.sql
-- 9494 Quack.
FROM quack_serve('quack:localhost:9494', token := getenv('QUACK_TOKEN'));

-- 9495: POST /sql {"sql": "..."}; POST /inbox any JSON, read it from quackapi_jobs; GET /profile?sql=…;
-- POST /mcp/ is the dev MCP server: tools query and execute, each a native JSON post to /sql, collected and unnested as receipts.
-- The inbox queue (quackapi_jobs) lives in dev.duckdb: jobs still queued are lost when the file is reset.
CREATE QUEUE inbox;
CREATE OR REPLACE ROUTE sql POST '/sql' AS SELECT * FROM quack_query('quack:localhost:9494', $sql, token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE ROUTE inbox POST '/inbox' STATUS 201 AS SELECT quackapi_enqueue('inbox', $body::JSON) AS id;
-- A middleware that stops the request sends its body raw as application/json, which is what MCP clients read.
-- The fixed replies are a MAP keyed by method; a tool call's text is the /sql reply (rows, or the DuckDB error).
-- Notifications carry no id and get 202; the body must not be empty or quackapi answers 500.
CREATE GROUP mcp WITH (prefix='/mcp');
CREATE OR REPLACE ROUTE mcp POST '/' IN GROUP mcp AS SELECT '' AS text;
CREATE OR REPLACE MIDDLEWARE mcp BEFORE GROUP mcp AS
WITH msg AS (
    SELECT $body::JSON -> '$.id' AS id, $body::JSON ->> '$.method' AS method,
           coalesce($body::JSON ->> '$.params.arguments.sql', $body::JSON ->> '$.params.arguments.statement') AS sql
), posted AS (
    SELECT id, method, array_agg(quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', sql)::VARCHAR)) AS receipts
    FROM msg WHERE method = 'tools/call' GROUP BY id, method
), called AS (
    SELECT id, method FROM msg WHERE method IS DISTINCT FROM 'tools/call'
    UNION ALL BY NAME
    SELECT id, method,
           coalesce(try_cast(r.body AS JSON), json_object('detail', coalesce(r.error, r.body))) AS reply,
           CASE WHEN r.status = 200 THEN coalesce(json_exists(reply, '$.detail'), false) ELSE true END AS failed
    FROM posted CROSS JOIN UNNEST(receipts) AS t(r)
)
SELECT false AS allow, CASE WHEN id IS NULL THEN 202 ELSE 200 END AS status,
       json_object('jsonrpc', '2.0', 'id', id, 'result', coalesce(
           MAP {'initialize': '{"protocolVersion": "2025-06-18", "serverInfo": {"name": "dev", "version": "1"}, "capabilities": {"tools": {}}}',
                'ping': '{}',
                'tools/list': '{"tools": [{"name": "query", "description": "Run any SQL on dev, reads and writes. Returns the rows as JSON; a failure returns the DuckDB error.", "inputSchema": {"type": "object", "properties": {"sql": {"type": "string"}}, "required": ["sql"]}}, {"name": "execute", "description": "Same as query, for callers that name it execute.", "inputSchema": {"type": "object", "properties": {"statement": {"type": "string"}}, "required": ["statement"]}}]}'}[method]::JSON,
           json_object('content', [json_object('type', 'text', 'text', reply::VARCHAR)], 'isError', failed)))::VARCHAR AS body,
       NULL::VARCHAR AS header_name, NULL::VARCHAR AS header_value
FROM called;
-- query_timeout_ms: a git commit's hooks run ~60 s, past quackapi's 30 s default. Longer work runs backgrounded
-- inside the pipe ('cmd > log 2>&1 & echo $! |') and a later read_lines reads its log.
-- Response cap 64 MiB (default 16): one transcript line reaches 21 MB; 32 parallel replies stay under 2 GiB.
-- Bigger self-dispatch reads write Parquet on dev and return a count.
SET GLOBAL quackapi_max_response_bytes = 67108864;
FROM quackapi_serve(9495, host := '127.0.0.1', query_timeout_ms := 120000);
-- quackapi_serve switches logging off.
CALL enable_logging(['QueryLog', 'HTTP', 'Quack', 'Metrics'], storage := 'file', storage_path := getenv('QUACK_NATIVE_LOG'), storage_buffer_size := 0);

.read server/agent.sql
.read server/lake.sql
.read server/branches.sql

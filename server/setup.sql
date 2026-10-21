-- Dev DuckDB. launchd runs `duckdb -bail ~/.duck/db/dev.duckdb -init setup.sql` and keeps stdin open.
-- Dev boots ~/.duck/deploy/server/setup.sql, a checkout of GitHub main. A save here changes nothing until it is
-- pushed to main; the watcher checks main out within 30 s and restarts dev when server/ changed.
-- The rest is read from server/*.sql, one concern per file, relative to the checkout root: the launchd wrapper starts
-- DuckDB in ~/.duck/deploy and CI in its checkout (.read expands no ~). The last step moves into ~/inframe.
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
.read server/extensions.sql
.read server/macros.sql
CALL enable_logging(['QueryLog', 'HTTP', 'Quack', 'Metrics'], storage := 'file', storage_path := getenv('QUACK_NATIVE_LOG'), storage_buffer_size := 0);
.read server/profile.sql
-- 9494 Quack.
FROM quack_serve('quack:localhost:9494', token := getenv('QUACK_TOKEN'));

-- 9495: POST /sql {"sql": "..."}; POST /inbox any JSON, read it from quackapi_jobs; GET /profile?sql=…;
-- POST /mcp/: every tool posts its SQL unchanged to /sql; query caps its reply at 50 rows / 8 KiB.
-- The inbox queue (quackapi_jobs) lives in dev.duckdb: jobs still queued are lost when the file is reset.
CREATE QUEUE inbox;
CREATE OR REPLACE ROUTE sql POST '/sql' AS SELECT * FROM quack_query('quack:localhost:9494', $sql, token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE ROUTE inbox POST '/inbox' STATUS 201 AS SELECT quackapi_enqueue('inbox', $body::JSON) AS id;
-- A middleware that stops the request sends its body raw as application/json, which is what MCP clients read.
-- The fixed replies are a MAP keyed by method; a tool call's text is the /sql reply (rows, or the DuckDB error).
-- Notifications carry no id and get 202; the body must not be empty or quackapi answers 500.
CREATE GROUP mcp WITH (prefix='/mcp');
CREATE OR REPLACE ROUTE mcp POST '/' IN GROUP mcp AS SELECT '' AS text;
.read server/mcp.sql
-- query_timeout_ms: a git commit's hooks run ~60 s, past quackapi's 30 s default. Longer work runs backgrounded
-- inside the pipe ('cmd > log 2>&1 & echo $! |') and a later read_lines reads its log.
-- Response cap 64 MiB (default 16): one transcript line reaches 21 MB; 32 parallel replies stay under 2 GiB.
-- Bigger self-dispatch reads write Parquet on dev and return a count.
SET GLOBAL quackapi_max_response_bytes = 67108864;
FROM quackapi_serve(9495, host := '127.0.0.1', query_timeout_ms := 120000);
-- quackapi_serve also sets preserve_insertion_order = false, so /sql returned a sorted result in shuffled
-- 2,048-row vectors (SELECT * FROM range(100000) ORDER BY range came back starting at 49152 or 98304).
SET GLOBAL preserve_insertion_order = true;
-- quackapi_serve switches logging off.
CALL enable_logging(['QueryLog', 'HTTP', 'Quack', 'Metrics'], storage := 'file', storage_path := getenv('QUACK_NATIVE_LOG'), storage_buffer_size := 0);

.read server/lake.sql
.read server/fs.sql
.read server/agent.sql
.read server/blocks.sql
.read server/blocks_refresh.sql
.read server/messages.sql
.read server/docs.sql
.read server/ext_catalog.sql
.read server/host.sql
.read server/processes.sql
.read server/reaper.sql
-- Dev works in the inframe checkout: duck_tails calls take '.' or no path at all.
SELECT content FROM read_text($cmd$mkdir -p ~/inframe && echo ok |$cmd$);
FROM cd(getenv('HOME') || '/inframe');

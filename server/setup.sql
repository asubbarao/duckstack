-- Dev DuckDB. launchd runs `duckdb -bail ~/.duck/db/dev.duckdb -init setup.sql` and keeps stdin open.
-- Dev boots ~/.duck/deploy/server/setup.sql, the duckdb-skills branch `deploy`. A save here changes nothing until
-- it is committed and the branch moved: git branch -f deploy <commit>; the watcher restarts dev within 30 s.
SET GLOBAL extension_directory = '/Users/aloksubbarao/.duck/extensions';
SET GLOBAL secret_directory = '/Users/aloksubbarao/.duck/secrets';
SET GLOBAL temp_directory = '/Users/aloksubbarao/.duck/tmp';
-- DuckDB's performance guide: 1-4 GB per thread. 10 threads x 1.6 GB; RSS runs 1.5-2.5 GB above this
-- (reader/JSON allocations are untracked), and the 48 GB machine keeps ~30 GB for everything else.
SET GLOBAL memory_limit = '16GB';
SET GLOBAL threads = 10;
SET GLOBAL TimeZone = 'UTC';
SET GLOBAL http_retries = 0;

-- INSTALL is a no-op once a file exists, so without this every boot reloads the first build ever downloaded.
-- A child process updates the files before anything below loads them; offline, it prints the error and boot goes on.
INSTALL shellfs FROM community; LOAD shellfs;
SELECT content FROM read_text($u$/opt/homebrew/bin/duckdb -csv :memory: -c "SET extension_directory = '/Users/aloksubbarao/.duck/extensions'; UPDATE EXTENSIONS;" 2>&1; true |$u$);
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
INSTALL sazgar FROM community; LOAD sazgar;
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
-- Dev works in the inframe checkout: duck_tails calls take '.' or no path at all.
FROM cd(getenv('HOME') || '/inframe');

ATTACH IF NOT EXISTS 'ducklake:/Users/aloksubbarao/.duck/lake/duckstack/catalog.ducklake' AS lake
    (DATA_PATH '/Users/aloksubbarao/.duck/lake/duckstack/data/', DATA_INLINING_ROW_LIMIT 0);

CALL enable_logging(['QueryLog', 'HTTP', 'Quack'], storage := 'file', storage_path := getenv('QUACK_NATIVE_LOG'), storage_buffer_size := 0);

-- Extension docs: lake.agents.ext_fetch keeps every fetch (url, fetched_at, response {status, body}); agents.ext_docs is
-- each fetch with its page as markdown (a community page carries the extension's whole function reference). Daily, the
-- community list and every extension page it links are fetched again: one curl per url, four /sql bodies run in order.
CREATE SCHEMA IF NOT EXISTS agents;
CREATE OR REPLACE VIEW agents.ext_docs AS
SELECT urlpattern_extract('https://duckdb.org/community_extensions/extensions/:name.html', url, 'name') AS extension, url, fetched_at,
       response ->> 'status' AS status,
       duck_blocks_to_md(html_to_duck_blocks((response ->> 'body')::HTML)) AS markdown
FROM lake.agents.ext_fetch;
SELECT cron($$
SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', string_agg(printf($s$INSERT INTO lake.agents.ext_fetch BY NAME
SELECT '%s' AS url, now() AS fetched_at, json_object('status', 200, 'body', content) AS response
FROM read_text('curl -sSL --fail --max-time 30 %s |')$s$, url, url), e';\n'))).status
FROM (SELECT 'https://duckdb.org/community_extensions/list_of_extensions' AS url
      UNION
      SELECT url_resolve(f.url, l.href) AS url FROM lake.agents.ext_fetch f
      CROSS JOIN UNNEST(html_extract_links(parse_html(f.response ->> 'body'))) AS u(l)
      WHERE f.url = 'https://duckdb.org/community_extensions/list_of_extensions'
        AND urlpattern_test('https://duckdb.org/community_extensions/extensions/:name.html', url_resolve(f.url, l.href)))
GROUP BY hash(url) % 4
$$, '0 15 3 * * *');

-- What each local branch changed since it left origin/staging, and whether origin has it: the files a PR
-- shows, with no gh. branch_point = shared commits that no other shared commit has as a parent (git's
-- merge base). One row per branch and changed file; filter with WHERE branch_name = ….
CREATE OR REPLACE VIEW branch_diff AS
WITH local_branches AS (
    SELECT * FROM git_branches() WHERE NOT is_remote
), remote_branches AS (
    SELECT branch_name AS remote_branch_name, commit_hash AS remote_commit_hash FROM git_branches() WHERE is_remote
), tracked_branches AS (
    SELECT local_branches.*, remote_branches.remote_branch_name, remote_branches.remote_commit_hash,
           remote_branches.remote_commit_hash IS NOT DISTINCT FROM local_branches.commit_hash AS is_pushed
    FROM local_branches
    LEFT JOIN remote_branches ON remote_branches.remote_branch_name = 'origin/' || local_branches.branch_name
), staging_commits AS (
    SELECT commit_hash FROM git_log('.', 'origin/staging')
), staging_parent_edges AS (
    SELECT commit_hash, parent_hash FROM git_parents('.', 'origin/staging')
), branch_history AS (
    SELECT tracked_branches.branch_name, history.commit_hash
    FROM tracked_branches, LATERAL git_log_each(tracked_branches.repo_path, tracked_branches.commit_hash) history
), shared_history AS (
    SELECT * FROM branch_history SEMI JOIN staging_commits USING (commit_hash)
), shared_parents AS (
    SELECT shared_history.branch_name, staging_parent_edges.parent_hash AS commit_hash
    FROM shared_history JOIN staging_parent_edges USING (commit_hash)
), branch_points AS (
    SELECT branch_name, commit_hash AS branch_point FROM shared_history
    ANTI JOIN shared_parents USING (branch_name, commit_hash)
)
SELECT tracked_branches.*, branch_points.branch_point, changed_file.* EXCLUDE (repo_path),
       git_uri(tracked_branches.repo_path, changed_file.file_path, branch_points.branch_point) AS before_uri,
       git_uri(tracked_branches.repo_path, changed_file.file_path, tracked_branches.commit_hash) AS after_uri
FROM tracked_branches
JOIN branch_points USING (branch_name)
CROSS JOIN LATERAL git_diff_tree_each(tracked_branches.repo_path, branch_points.branch_point, tracked_branches.commit_hash) changed_file;

-- Every branch_diff file with both ends' blob metadata and the branch's commit facts. Ahead/behind match
-- `git rev-list --left-right --count origin/staging...<branch>`. A file's blob reads are correlated LATERALs,
-- so WHERE branch_name = … reads only that branch; the side a file lacks gets a NULL uri, because a WHERE
-- inside the LATERAL does not stop the read.
-- Definitions each branch_diff file added, removed or modified: sitting_duck parses both ends; a declaration
-- wrapping a same-named definition (TS `const x` around its declarator) is dropped so each name counts once,
-- and the two ends join on qualified_name (scope path with per-name index), not on name.
CREATE OR REPLACE VIEW branch_definition_changes AS
WITH file_sides AS (
    SELECT branch_diff.branch_name, branch_diff.file_path, 'before' AS side, file_read.text
    FROM branch_diff, LATERAL git_read_each(branch_diff.before_uri) file_read
    WHERE branch_diff.status <> 'added'
    UNION ALL
    SELECT branch_diff.branch_name, branch_diff.file_path, 'after' AS side, file_read.text
    FROM branch_diff, LATERAL git_read_each(branch_diff.after_uri) file_read
    WHERE branch_diff.status <> 'deleted'
), nodes AS (
    SELECT branch_name, file_path, side, unnest(parse_ast_list(text, detect_language(file_path)), recursive := true)
    FROM file_sides
    WHERE detect_language(file_path) IS NOT NULL
), definitions AS (
    SELECT * FROM nodes WHERE is_definition(semantic_type) AND name <> ''
), wrapper_definitions AS (
    SELECT parent.branch_name, parent.file_path, parent.side, parent.node_id
    FROM definitions parent JOIN definitions child
      ON child.branch_name = parent.branch_name AND child.file_path = parent.file_path AND child.side = parent.side
     AND child.parent_id = parent.node_id AND child.name = parent.name
), own_definitions AS (
    SELECT * FROM definitions ANTI JOIN wrapper_definitions USING (branch_name, file_path, side, node_id)
), before_definitions AS (
    SELECT * FROM own_definitions WHERE side = 'before'
), after_definitions AS (
    SELECT * FROM own_definitions WHERE side = 'after'
)
SELECT coalesce(after_definitions.branch_name, before_definitions.branch_name) AS branch_name,
       coalesce(after_definitions.file_path, before_definitions.file_path) AS file_path,
       coalesce(after_definitions.qualified_name, before_definitions.qualified_name) AS qualified_name,
       coalesce(after_definitions.name, before_definitions.name) AS name,
       coalesce(after_definitions.type, before_definitions.type) AS node_type,
       CASE WHEN before_definitions.node_id IS NULL THEN 'added'
            WHEN after_definitions.node_id IS NULL THEN 'removed'
            WHEN after_definitions.descendant_count <> before_definitions.descendant_count THEN 'modified'
            WHEN after_definitions.peek <> before_definitions.peek THEN 'modified'
            ELSE 'unchanged' END AS change,
       before_definitions.start_line AS before_start_line, before_definitions.end_line AS before_end_line,
       after_definitions.start_line AS after_start_line, after_definitions.end_line AS after_end_line,
       before_definitions.descendant_count AS before_descendant_count, after_definitions.descendant_count AS after_descendant_count,
       before_definitions.peek AS before_peek, after_definitions.peek AS after_peek
FROM before_definitions FULL JOIN after_definitions
  ON after_definitions.branch_name = before_definitions.branch_name
 AND after_definitions.file_path = before_definitions.file_path
 AND after_definitions.qualified_name = before_definitions.qualified_name;

-- 9494 Quack. 4318 OTLP/HTTP into the lake: otlp_serve creates lake.otel.otlp_* (logs, traces, metrics_sum, _gauge,
-- _histogram, _exp_histogram) and commits buffered rows about every 5 s; otlp_stop() commits them, a kill drops them.
-- After its commits it runs CHECKPOINT lake, and it sets the lake's GLOBAL expire_older_than / delete_older_than to
-- maintenance_retention_ms (default 15 min): every lake table's snapshots older than that are expired. 30 days here.
FROM quack_serve('quack:localhost:9494', token := getenv('QUACK_TOKEN'));
CREATE SCHEMA IF NOT EXISTS lake.otel;
FROM otlp_serve('otlp:127.0.0.1:4318', catalog := 'lake', schema := 'otel', disable_auth := true, maintenance_retention_ms := 2592000000);

-- 9495: POST /sql {"sql": "..."}; POST /inbox any JSON, read it from quackapi_jobs; GET /profile?sql=…;
-- POST /mcp/ is the dev MCP server: tools query and execute, each a curl to /sql through shellfs, so calls run in parallel.
-- The inbox queue (quackapi_jobs) lives in dev.duckdb: jobs still queued are lost when the file is reset.
CREATE QUEUE inbox;
CREATE OR REPLACE ROUTE sql POST '/sql' AS SELECT * FROM quack_query('quack:localhost:9494', $sql, token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE ROUTE inbox POST '/inbox' STATUS 201 AS SELECT quackapi_enqueue('inbox', $body::JSON) AS id;
-- GET /profile?sql=…: runs it under EXPLAIN ANALYZE; the query-level numbers as columns, and DuckDB's whole profile.
CREATE OR REPLACE ROUTE profile GET '/profile' AS
SELECT p ->> 'latency' AS latency_s, p ->> 'cpu_time' AS cpu_s, p ->> 'system_peak_buffer_memory' AS peak_buffer_bytes,
       p ->> 'cumulative_rows_scanned' AS rows_scanned, p ->> 'total_bytes_read' AS bytes_read, p ->> 'total_bytes_written' AS bytes_written,
       p AS profile
FROM (SELECT explain_value::JSON AS p FROM quack_query('quack:localhost:9494', 'EXPLAIN (ANALYZE, FORMAT json) ' || $sql, token := getenv('QUACK_TOKEN')));
-- A middleware that stops the request sends its body raw as application/json, which is what MCP clients read.
-- The fixed replies are a MAP keyed by method; a tool call's text is the /sql reply (rows, or the DuckDB error).
-- Notifications carry no id and get 202; the body must not be empty or quackapi answers 500.
CREATE GROUP mcp WITH (prefix='/mcp');
CREATE OR REPLACE ROUTE mcp POST '/' IN GROUP mcp AS SELECT '' AS text;
CREATE OR REPLACE MIDDLEWARE mcp BEFORE GROUP mcp AS
WITH msg AS (
    SELECT $body::JSON -> '$.id' AS id, $body::JSON ->> '$.method' AS method
), called AS (  -- a tool call curls /sql through shellfs; the body is a quoted heredoc, so nothing in it is escaped
    FROM msg WHERE method IS DISTINCT FROM 'tools/call'
    UNION ALL BY NAME
    SELECT id, method, json AS reply, json_exists(json, '$.detail') AS failed
    FROM msg, read_json_objects(tera_render($t$curl -s -H 'content-type: application/json' --data-binary @- http://127.0.0.1:9495/sql <<'MCP_BODY'
{{ body }}
MCP_BODY
|$t$, json_object('body', json_object('sql', coalesce($body::JSON ->> '$.params.arguments.sql', $body::JSON ->> '$.params.arguments.statement'))::VARCHAR), autoescape := false), format := 'unstructured')
    WHERE method = 'tools/call'
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
CALL enable_logging(['QueryLog', 'HTTP', 'Quack'], storage := 'file', storage_path := getenv('QUACK_NATIVE_LOG'), storage_buffer_size := 0);

-- Agent transcripts (Claude Code ~/.claude/projects, Codex ~/.codex), read natively, one Parquet per folder at the folder's
-- own path under ~/.duck/lake/agent.
-- agent.entries: PR #1576's entries shape over one find: hostfs columns, the reader, and the statement that copies the
-- file's whole folder (a glob read) to its stored file. read_json keeps every top-level field as a column of JSON
-- (maximum_depth 1, map inference off): the same shape in every folder. Map inference on turns a folder's ~170 top-level
-- fields into one MAP; inferred deeper, a field is a STRUCT in one folder and a MAP in another, which union_by_name cannot
-- merge. maximum_object_size 32 MB fits the largest line (~21 MB); the reader's buffers are twice it per thread.
-- Nothing here errors on a machine without transcripts: glob() lists an empty set where find exits 1, so nothing is
-- copied and agent.lines is never posted (read_parquet fails on an empty file list and takes no subquery).
CREATE SCHEMA IF NOT EXISTS agent;
CREATE OR REPLACE VIEW agent.entries AS
SELECT path, parse_dirpath(path) AS parent, file_name(path) AS name, file_extension(path) AS ext, file_size(path) AS bytes,
       file_last_modified(path) AS modified, 'read_json' AS reader, '~/.duck/lake/agent' || parent || '.parquet' AS stored,
       printf($s$SELECT content FROM read_text('mkdir -p %s |');
COPY (SELECT * FROM read_json('%s/*.jsonl*', format := 'newline_delimited', maximum_depth := 1, map_inference_threshold := -1, sample_size := -1,
      maximum_object_size := 33554432, ignore_errors := true, union_by_name := true, filename := 'transcript')) TO '%s' (FORMAT parquet)$s$,
              parse_dirpath(stored), parent, stored) AS sql_statement
FROM (SELECT file AS path FROM glob('~/.claude/projects/**/*.jsonl*')
      UNION ALL SELECT file FROM glob('~/.codex/*sessions/**/*.jsonl*'));
-- One post per folder; the posts of one SELECT run at the same time. Boot copies every folder (111, 3.9 GB: 21 s);
-- every 5 minutes the cron replaces the folders holding a file modified since yesterday. A replaced file is written as
-- tmp_<name> and renamed, so agent.lines, posted after the copies with the stored files' literal list, never reads a
-- partial file. It keeps the lines whose transcript still exists (a session archived out of a folder leaves its old copy).
SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', sql_statement)).status
FROM (SELECT DISTINCT parent, sql_statement FROM agent.entries);
SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', printf($s$CREATE OR REPLACE VIEW agent.lines AS
SELECT * FROM read_parquet([%s], union_by_name := true) SEMI JOIN agent.entries e ON e.path = transcript$s$, files))).status
FROM (SELECT string_agg('$q$' || file || '$q$', ', ') AS files FROM glob('~/.duck/lake/agent/**/*.parquet')
      WHERE NOT starts_with(file_name(file), 'tmp_'))
WHERE files IS NOT NULL;
SELECT cron($$SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', sql_statement)).status
FROM (SELECT DISTINCT parent, sql_statement FROM agent.entries WHERE modified >= current_date - INTERVAL 1 DAY);
SELECT quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', printf($s$CREATE OR REPLACE VIEW agent.lines AS
SELECT * FROM read_parquet([%s], union_by_name := true) SEMI JOIN agent.entries e ON e.path = transcript$s$, files))).status
FROM (SELECT string_agg('$q$' || file || '$q$', ', ') AS files FROM glob('~/.duck/lake/agent/**/*.parquet')
      WHERE NOT starts_with(file_name(file), 'tmp_'))
WHERE files IS NOT NULL$$, '0 */5 * * * *');

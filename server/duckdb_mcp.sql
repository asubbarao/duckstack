-- Agent entry points; execution stays on the selected QuackAPI/Quack server.
INSTALL duckdb_mcp FROM community; LOAD duckdb_mcp;
PRAGMA mcp_publish_tool('query_with_limit',
  'The default way to run SQL on the dev DuckDB (complete SQL, DDL/DML, native readers, ShellFS, HTTP). The final SELECT is capped at 20 rows unless it has its own outer LIMIT, so exploration never floods context: start at LIMIT 2-3, widen once the query is right. default_limit_applied in the receipt says whether the cap was added. Writes are not limited. Returns request ID, submitted and executed SQL, and the full HTTP receipt with errors. Never replay an uncertain write.',
  $forward$WITH submitted AS (
  SELECT $sql AS submitted_sql, uuid()::VARCHAR AS request_id
), parsed AS (
  SELECT *, try(parse_statements(submitted_sql)) AS statements FROM submitted
), classified AS (
  SELECT *, statements[-1] AS final_sql, json_serialize_sql(final_sql) AS ast FROM parsed
), prepared AS (
  SELECT *, coalesce(ast->>'error' = 'false'
    AND len(list_filter(json_extract(ast, '$.statements[0].node.modifiers[*].limit'), x -> x <> 'null'::JSON)) = 0, false) AS default_limit_applied,
    CASE WHEN default_limit_applied
      THEN array_to_string(list_concat(statements[:-2], [printf('SELECT * FROM (%s) AS agent_result LIMIT 20', final_sql)]), ';' || chr(10))
      ELSE submitted_sql END AS executed_sql
  FROM classified
), sent AS (
  SELECT request_id, submitted_sql, executed_sql, default_limit_applied,
    http_post('http://127.0.0.1:9495/sql', MAP{'Content-Type':'application/json'},
      json_object('sql', printf('/* request_id=%s */%s%s', request_id, chr(10), executed_sql))) AS response
  FROM prepared
)
SELECT *, response.status AS status, response.reason AS reason, response.body AS body FROM sent$forward$,
  '{"sql":{"type":"string","description":"Complete SQL program; final SELECT defaults to LIMIT 20 unless explicitly limited"}}',
  '["sql"]', 'json');
PRAGMA mcp_publish_tool('query_no_limit',
  'Runs SQL on the dev DuckDB exactly as written, with no row cap added. Do not use this to explore: a wide SELECT here can return tens of thousands of rows into context. Use it only when you already know the result is small (you ran it through query_with_limit first) or for writes and programs whose output you need whole. Returns request ID, the SQL and the full HTTP receipt with errors. Never replay an uncertain write.',
  $forward$WITH submitted AS (
  SELECT $sql AS submitted_sql, uuid()::VARCHAR AS request_id
), sent AS (
  SELECT request_id, submitted_sql, submitted_sql AS executed_sql, false AS default_limit_applied,
    http_post('http://127.0.0.1:9495/sql', MAP{'Content-Type':'application/json'},
      json_object('sql', printf('/* request_id=%s */%s%s', request_id, chr(10), submitted_sql))) AS response
  FROM submitted
)
SELECT *, response.status AS status, response.reason AS reason, response.body AS body FROM sent$forward$,
  '{"sql":{"type":"string","description":"Complete SQL program, sent as written with no LIMIT added"}}',
  '["sql"]', 'json');
-- Search and drill-down share the SQL used by the five-minute stream refresh.
.read /Users/aloksubbarao/duckdb-skills/server/agent_base.sql
.read /Users/aloksubbarao/duckdb-skills/server/agent_stream_tools.sql
PRAGMA mcp_publish_tool('self_dispatch',
  'Primary row-driven execution tool. Pass a SELECT with a statement column and optional source keys; only returned rows execute through the selected dev QuackAPI. Returns full source rows, statements and raw HTTP receipts, including failures; no row cap. Zero source rows means no calls. Use WHERE NOT EXISTS for missing work. Never replay uncertain writes; dependent statements belong in one ordered SQL body.',
  $dispatch$WITH statements AS (FROM query($rows_sql)),
posted AS (
  SELECT array_agg({source: statements, response:
    http_post('http://127.0.0.1:9495/sql', MAP{'Content-Type':'application/json'}, json_object('sql', statement))}) AS receipts
  FROM statements
)
SELECT receipt.source AS source, receipt.source.statement AS statement,
       receipt.response.status AS status, receipt.response.body AS body,
       receipt.response AS response
FROM posted CROSS JOIN UNNEST(receipts) AS t(receipt)$dispatch$,
  '{"rows_sql":{"type":"string","description":"SELECT ... AS statement FROM ...; filter here before execution"}}',
  '["rows_sql"]', 'json');
PRAGMA mcp_publish_tool('ext_docs',
  'Read the complete captured GitHub README for an extension, without page navigation.',
  'SELECT extension_name, readme FROM agents.ext_docs WHERE extension_name = $extension',
  '{"extension":{"type":"string"}}', '["extension"]', 'markdown');
-- A web page as text blocks (http_client fetches, webbed parses), so no agent reads raw HTML into its context:
-- the shellfs docs page is 134,408 raw characters and 3,692 characters of blocks.
INSTALL http_client FROM community; LOAD http_client; INSTALL webbed FROM community; LOAD webbed;
PRAGMA mcp_publish_tool('web_read',
  'Fetch a URL with http_client and return its readable blocks (headings, paragraphs, code, tables) in page order, with the HTTP status and the raw size, instead of raw HTML.',
  -- http_get(url VARCHAR [, headers MAP(VARCHAR, VARCHAR), params MAP(VARCHAR, VARCHAR)]) -> JSON {status, reason, body}
  --   (http_client; http_head(url) and http_post(url, headers MAP, body JSON) take the same shape)
  -- html_to_duck_blocks(html HTML|VARCHAR) -> STRUCT(kind, element_type, content, level, encoding,
  --   attributes MAP(VARCHAR, VARCHAR), element_order)[]   (webbed; kind is 'block' or 'inline')
  $web$WITH fetched AS (SELECT http_get($url) AS response),
page AS (SELECT response->>'$.status' AS status, length(response->>'$.body') AS raw_chars,
    html_to_duck_blocks((response->>'$.body')::HTML) AS blocks FROM fetched)
SELECT status, raw_chars, b.element_order AS n, b.element_type AS type, trim(b.content) AS text
FROM page CROSS JOIN UNNEST(blocks) AS t(b)
WHERE b.kind = 'block' AND length(trim(b.content)) > 0
ORDER BY n$web$,
  '{"url":{"type":"string"}}', '["url"]', 'markdown');
-- Git, CI logs and rendering as tools, so no agent needs a local client for them.
PRAGMA mcp_publish_tool('git_tree',
  'Files of a local git repository at a ref (duck_tails). repo is an absolute path to a checkout or bare clone; ref is HEAD, a branch, a tag or a sha.',
  'SELECT file_path, file_ext, kind, size_bytes, git_uri FROM git_tree($repo, $ref) WHERE kind = ''file'' ORDER BY file_path LIMIT 100',
  '{"repo": {"type": "string"}, "ref": {"type": "string", "description": "default HEAD"}}', '["repo", "ref"]', 'markdown');
PRAGMA mcp_publish_tool('git_read',
  'One file from a local git repository at a ref, as text (duck_tails). Binary files come back with text NULL.',
  'SELECT file_path, ref, size_bytes, encoding, text FROM git_read(''git://'' || $repo || ''/'' || $path || ''@'' || $ref)',
  '{"repo": {"type": "string"}, "path": {"type": "string", "description": "path inside the repo"}, "ref": {"type": "string", "description": "HEAD, branch, tag or sha"}}', '["repo", "path", "ref"]', 'markdown');
PRAGMA mcp_publish_tool('ci_hunt',
  'Parse a CI job log inside a GitHub Actions log zip with duck_hunt. zip is an absolute path; glob selects files inside it (e.g. *Backend Tests Shard*.txt); format is a duck_hunt format name, auto, or regexp:<pattern with named groups>.',
  'SELECT event_type, status, severity, tool_name, ref_file, ref_line, test_name, message, execution_time, log_file, log_line_start
   FROM read_duck_hunt_log(''zip://'' || $zip || ''/'' || $glob, $format) LIMIT 100',
  '{"zip": {"type": "string"}, "glob": {"type": "string"}, "format": {"type": "string"}}', '["zip", "glob", "format"]', 'markdown');
PRAGMA mcp_publish_tool('render',
  'Render a named Tera template file on the selected server with a JSON-object context. Sibling templates are loaded for includes and inheritance. Returns plain rendered text; does not execute it. Autoescape is false for SQL/scripts/text; escape untrusted HTML values explicitly. Business logic belongs in the calling SQL, not templates.',
  $render$SELECT tera_render(parse_filename($template), $ctx::JSON,
    autoescape := false, template_path := parse_dirpath($template) || '/*') AS rendered$render$,
  '{"template":{"type":"string","description":"Absolute template file path; sibling files are loaded"},"ctx":{"type":"string","description":"JSON object of prepared template data"}}',
  '["template","ctx"]','text');
PRAGMA mcp_publish_tool('shellfs',
 'Run a Bash command on the selected server through ShellFS and QuackAPI. Primary host-command tool. Returns raw line content, line numbers and byte offsets, up to 20 rows, plus the HTTP/server/database error receipt. Nonzero command exits are errors. For structured stdout use query/sql with read_csv or read_json. Use explicit paths; do not assume the client working directory. Never replay uncertain writes. No per-command deadline is enforced.',
 $shellfs$WITH source AS (
 SELECT $command AS command, uuid()::VARCHAR AS request_id
), rendered AS (
 SELECT *, tera_render('reader.tera',
 json_object('reader','read_lines','interpreter','/bin/bash -o pipefail','script',command,
 'heredoc','END_'||replace(request_id,'-',''),'sql_tag','pipe_'||replace(request_id,'-',''),'row_limit',20),
 autoescape := false, template_path := coalesce(nullif(getenv('DATASWARM_ROOT'),''),getenv('HOME')||'/duckdb-dataswarm')||'/duckdb/templates/*.tera') AS q
 FROM source
)
SELECT json_object('request_id',request_id,'response',
 http_post('http://127.0.0.1:9495/sql',MAP{'Content-Type':'application/json'},
 json_object('sql',printf('/* request_id=%s */%s%s',request_id,chr(10),q)))) AS receipt FROM rendered$shellfs$,
 '{"command":{"type":"string","description":"Bash program; executed on the selected server, not the client"}}',
 '["command"]','text');
-- dataswarm:begin
-- Source: duckdb/macros/self_dispatch.sql
LOAD http_client; LOAD quackapi;
CREATE SCHEMA IF NOT EXISTS agents;
CREATE OR REPLACE MACRO agents.dispatch_sql(statements, endpoint := 'http://127.0.0.1:9495/sql') AS TABLE
WITH statement_rows AS (
  SELECT unnest(statements) AS statement, generate_subscripts(statements, 1) AS position
), posted AS (
  SELECT array_agg({position: position, statement: statement, response:
    http_post_form(endpoint, MAP{}, MAP{'sql': statement})}
    ORDER BY position) AS receipts
  FROM statement_rows
)
SELECT receipt.position, receipt.statement, receipt.response.status AS status,
       json_extract_string(receipt.response.body, '$') AS body
FROM posted CROSS JOIN UNNEST(receipts) AS dispatched(receipt)
ORDER BY receipt.position;

CREATE OR REPLACE MACRO agents.dispatch_sequence(statements, endpoint := 'http://127.0.0.1:9495/sql') AS TABLE
FROM agents.dispatch_sql([array_to_string(statements, E'\n;\n')], endpoint := endpoint);

-- Source: duckdb/macros/hostfs.sql
LOAD hostfs;
CREATE SCHEMA IF NOT EXISTS agents;
CREATE OR REPLACE MACRO agents.hostfs_ls(root_path) AS TABLE
SELECT path, absolute_path(path) AS absolute_path, file_name(path) AS file_name,
       file_extension(path) AS file_extension, path_type(path) AS path_type,
       is_dir(path) AS is_dir, is_file(path) AS is_file, path_exists(path) AS path_exists,
       file_size(path) AS file_size, hsize(file_size) AS hsize,
       file_last_modified(path) AS file_last_modified
FROM ls(root_path)
WHERE NOT starts_with(file_name, '.')
  AND NOT list_contains(list_transform(parse_path(absolute_path), part -> starts_with(part, '.')), true)
  AND NOT list_has_any(parse_path(absolute_path), ['node_modules', 'dump', '__pycache__', 'venv', 'dist', 'build']);

-- Source: duckdb/mcp/self_dispatch.sql
PRAGMA mcp_publish_tool('dispatch_sql',
  'First diagnostic for column-parameter, literal-argument or unsupported lateral table-function binder errors: self-dispatch. Generate an ordinary table-function statement per input row with literal arguments; scalar HTTP returns each result as a per-row receipt. Returns statement, position, HTTP status and raw body. Inspect inner errors. Position does not schedule execution. Never replay uncertain writes.',
  $$SELECT * FROM agents.dispatch_sql($statements::VARCHAR[])$$,
  '{"statements":{"type":"array","items":{"type":"string"}}}', '["statements"]', 'markdown');
PRAGMA mcp_publish_tool('dispatch_sequence',
  'Submit one ordered SQL body for dependent DDL/DML. Does not add transaction statements or retries. Inspect state after failure.',
  $$SELECT * FROM agents.dispatch_sequence($statements::VARCHAR[])$$,
  '{"statements":{"type":"array","items":{"type":"string"}}}', '["statements"]', 'markdown');

-- Source: duckdb/mcp/hostfs.sql
PRAGMA mcp_publish_tool('hostfs_ls',
  'One directory with HostFS metadata, files and folders, excluding hidden/ignored entries and resolved hidden paths. Dispatch only surviving is_dir paths for the next wave.',
  $$SELECT * FROM agents.hostfs_ls($path::VARCHAR)$$,
  '{"path":{"type":"string","description":"Explicit directory on the selected server"}}', '["path"]', 'markdown');
-- Source: duckdb/macros/read_lines.sql
INSTALL read_lines FROM community;
LOAD read_lines;

-- Source: duckdb/macros/scalarfs.sql
INSTALL scalarfs FROM community;
LOAD scalarfs;

-- Source: duckdb/mcp/read_lines.sql
PRAGMA mcp_publish_tool('read_lines',
  'Read UTF-8 lines from an explicit path. Use a #L12-L24 path fragment for selected lines. Returns line_number, content, byte_offset and file_path. SQL read_lines supports more selector options.',
  $$SELECT * FROM read_lines($path::VARCHAR)$$,
  '{"path":{"type":"string","description":"Explicit path, glob, pipe, or URI; #L12-L24 fragments select lines in the path"}}',
  '["path"]', 'markdown');
-- dataswarm:end

PRAGMA mcp_server_start('http', 'localhost', getvariable('mcp_port'),
  '{"builtin_tools": false, "background": true, "default_result_format": "markdown"}');


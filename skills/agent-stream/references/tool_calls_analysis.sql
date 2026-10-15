-- Tool-call analysis over agent.tool_calls (dev). Each block is one bare SELECT; run any of them on dev.
-- Since Oct 9 = after the 2026-10-08 hooks.

-- 1. Daily mix: dev MCP vs Bash vs native file tools.
WITH t AS (SELECT ts::DATE AS day, CASE WHEN starts_with(tool, 'dev.') THEN 'dev_mcp' WHEN tool = 'Bash' THEN 'bash' WHEN tool IN ('Read', 'Edit', 'Write', 'Grep', 'Glob') THEN 'native_file' ELSE 'other' END AS kind FROM agent.tool_calls),
d AS (SELECT day, kind, len(list(kind)) AS n FROM t GROUP BY ALL),
p AS (PIVOT d ON kind USING sum(n) GROUP BY day)
SELECT day, coalesce(dev_mcp, 0) AS dev_mcp, coalesce(bash, 0) AS bash, coalesce(native_file, 0) AS native_file, coalesce(other, 0) AS other,
       round(100.0 * coalesce(dev_mcp, 0) / (coalesce(dev_mcp, 0) + coalesce(bash, 0) + coalesce(native_file, 0)), 1) AS dev_pct
FROM p ORDER BY day;

-- 2. What Bash calls do, before and since Oct 9 (purpose from the sitting_duck-parsed `calls`).
WITH b AS (SELECT session_id, ts, code, coalesce(calls, []) AS calls, is_error, CASE WHEN ts >= TIMESTAMPTZ '2026-10-09' THEN 'after' ELSE 'before' END AS era FROM agent.tool_calls WHERE tool = 'Bash'),
c AS (SELECT *, CASE
    WHEN contains(code, ':949') THEN 'dev over curl'
    WHEN list_has_any(calls, ['duckdb']) THEN 'duckdb CLI'
    WHEN list_has_any(calls, ['git', 'gh']) THEN 'git / gh'
    WHEN list_has_any(calls, ['python', 'python3', 'jq', 'node']) THEN 'json/python munging'
    WHEN list_has_any(calls, ['sed', 'awk', 'perl']) THEN 'sed/awk text edit or slice'
    WHEN list_has_any(calls, ['grep', 'rg', 'cat', 'head', 'tail', 'find', 'ls', 'wc', 'cut', 'sort', 'stat', 'du']) THEN 'file read/search'
    WHEN list_has_any(calls, ['curl', 'wget']) THEN 'http (curl)'
    WHEN list_has_any(calls, ['uv', 'uvx', 'npm', 'npx', 'pytest', 'make', 'cargo', 'cmake']) THEN 'build / test'
    WHEN list_has_any(calls, ['psql', 'pg_dump', 'podman', 'docker', 'aws']) THEN 'db / infra cli'
    WHEN list_has_any(calls, ['sleep', 'until', 'while']) THEN 'waiting / polling'
    ELSE 'other' END AS purpose FROM b)
SELECT purpose, len(list(era)) AS total, sum((era = 'before')::INT) AS before_oct9, sum((era = 'after')::INT) AS since_oct9,
       round(100.0 * sum(is_error::INT) / len(list(era)), 1) AS err_pct
FROM c GROUP BY purpose ORDER BY since_oct9 DESC;

-- 3. Which DuckDB extensions the SQL calls use since Oct 9.
WITH s AS (SELECT session_id, unnest(calls) AS fn FROM agent.tool_calls WHERE lang = 'sql' AND ts >= TIMESTAMPTZ '2026-10-09'),
fam AS (SELECT session_id, fn, CASE
    WHEN starts_with(fn, 'git_') THEN 'duck_tails (git_*)'
    WHEN starts_with(fn, 'read_duck_hunt') THEN 'duck_hunt'
    WHEN fn IN ('parse_ast_list', 'parse_ast', 'read_ast', 'detect_language') THEN 'sitting_duck'
    WHEN fn IN ('parse_tables', 'parse_functions', 'parse_statements', 'is_parsable') THEN 'parser_tools'
    WHEN fn IN ('read_lines', 'read_lines_lateral') THEN 'read_lines / shellfs pipe'
    WHEN fn IN ('ls', 'lsr', 'file_size', 'file_last_modified', 'path_type', 'hostfs_ls', 'is_dir') THEN 'hostfs'
    WHEN fn IN ('read_conversations', 'read_history', 'read_plans', 'read_todos') THEN 'agent_data'
    WHEN fn = 'tera_render' THEN 'tera'
    WHEN fn IN ('http_post', 'http_get', 'quackapi_post', 'quackapi_fetch') THEN 'http self-dispatch'
    WHEN fn IN ('read_text', 'read_blob') THEN 'read_text / read_blob'
    WHEN fn IN ('read_json', 'read_json_auto', 'read_ndjson', 'read_csv', 'read_csv_auto', 'read_parquet') THEN 'core readers'
    WHEN starts_with(fn, 'html_') THEN 'webbed'
    WHEN starts_with(fn, 'md_') THEN 'markdown'
    WHEN fn IN ('cron', 'cron_jobs') THEN 'cronjob'
    END AS family FROM s)
SELECT family, len(list(fn)) AS uses, len(list(DISTINCT session_id)) AS sessions FROM fam WHERE family IS NOT NULL GROUP BY family ORDER BY uses DESC;

-- 4. The shell commands run inside shellfs pipes ($cmd$ … |$cmd$), parsed with sitting_duck's bash grammar.
WITH s AS (SELECT session_id, string_split(code, '$cmd$') AS parts FROM agent.tool_calls WHERE lang = 'sql' AND ts >= TIMESTAMPTZ '2026-10-09' AND contains(code, '$cmd$')),
c AS (SELECT session_id, rtrim(trim(parts[2]), '|') AS cmd FROM s WHERE len(parts) >= 3),
p AS (SELECT session_id, list_distinct(list_transform(list_filter(parse_ast_list(cmd, 'bash'), lambda n: n.type = 'command_name'), lambda n: n.peek)) AS progs FROM c),
u AS (SELECT session_id, unnest(progs) AS prog FROM p)
SELECT prog, len(list(prog)) AS calls, len(list(DISTINCT session_id)) AS sessions FROM u GROUP BY prog ORDER BY calls DESC LIMIT 20;

-- 5. Error rate by tool since Oct 9, and the longest runs of consecutive errors.
WITH t AS (SELECT session_id, agent, ts, tool, is_error FROM agent.tool_calls WHERE ts >= TIMESTAMPTZ '2026-10-09'),
by_tool AS (SELECT tool, len(list(tool)) AS calls, sum(is_error::INT) AS errors, round(100.0 * errors / calls, 1) AS err_pct FROM t GROUP BY tool HAVING calls >= 200),
seq AS (SELECT session_id, agent, ts, tool, is_error, sum((NOT is_error)::INT) OVER (PARTITION BY session_id, agent ORDER BY ts) AS grp FROM t),
streaks AS (SELECT session_id, agent, grp, len(list(ts)) - 1 AS consecutive_errors, list(DISTINCT tool) AS tools FROM seq GROUP BY ALL)
SELECT 'tool' AS kind, tool AS name, calls, errors, err_pct, NULL AS tools FROM by_tool
UNION ALL
SELECT 'streak', left(session_id, 8) || '/' || agent, consecutive_errors, NULL, NULL, tools::VARCHAR FROM (SELECT * FROM streaks WHERE consecutive_errors >= 5 ORDER BY consecutive_errors DESC LIMIT 8)
ORDER BY kind DESC, err_pct DESC, calls DESC;

-- 6. Why calls fail since Oct 9: the error text, read from the transcript lines (the view keeps only result size).
WITH l AS (SELECT timestamp::TIMESTAMPTZ AS ts, record FROM read_parquet('/Users/aloksubbarao/.duck/claude_tool_calls/lines/*/*.parquet', hive_partitioning := true) WHERE type = 'user' AND timestamp::TIMESTAMPTZ >= TIMESTAMPTZ '2026-10-09'),
b AS (SELECT ts, unnest(from_json(json_extract(record, '$.message.content'), '["JSON"]')) AS blk FROM l WHERE json_type(json_extract(record, '$.message.content')) = 'ARRAY'),
e AS (SELECT DISTINCT json_extract_string(blk, '$.tool_use_id') AS id, left(coalesce(json_extract_string(blk, '$.content[0].text'), json_extract_string(blk, '$.content')), 300) AS txt FROM b WHERE json_extract_string(blk, '$.type') = 'tool_result' AND json_extract_string(blk, '$.is_error') = 'true'),
k AS (SELECT CASE
    WHEN contains(txt, 'BLOCKED by user hook') THEN 'hook: ' || trim(string_split(string_split(txt, 'BLOCKED by user hook: ')[2], '.')[1])
    WHEN contains(txt, 'user doesn''t want') THEN 'user rejected the call'
    WHEN contains(txt, 'Binder Error') THEN 'DuckDB Binder Error'
    WHEN contains(txt, 'Parser Error') THEN 'DuckDB Parser Error'
    WHEN contains(txt, 'Catalog Error') THEN 'DuckDB Catalog Error'
    WHEN contains(txt, 'Invalid Input Error') THEN 'DuckDB Invalid Input Error'
    WHEN contains(txt, 'IO Error') THEN 'DuckDB IO Error'
    WHEN contains(txt, 'Conversion Error') THEN 'DuckDB Conversion Error'
    WHEN contains(txt, 'ECONNREFUSED') THEN 'dev down (ECONNREFUSED)'
    WHEN contains(txt, 'Exit code') THEN 'shell non-zero exit'
    WHEN contains(txt, 'File has not been read') THEN 'Edit/Write before Read'
    WHEN contains(txt, 'String to replace not found') THEN 'Edit string not found'
    ELSE 'other' END AS kind FROM e)
SELECT left(kind, 110) AS kind, len(list(kind)) AS errors FROM k GROUP BY ALL ORDER BY errors DESC LIMIT 25;

-- 7. The "Invalid Input Error" messages since Oct 9, by first line.
WITH l AS (SELECT record FROM read_parquet('/Users/aloksubbarao/.duck/claude_tool_calls/lines/*/*.parquet', hive_partitioning := true) WHERE type = 'user' AND timestamp::TIMESTAMPTZ >= TIMESTAMPTZ '2026-10-09'),
b AS (SELECT unnest(from_json(json_extract(record, '$.message.content'), '["JSON"]')) AS blk FROM l WHERE json_type(json_extract(record, '$.message.content')) = 'ARRAY'),
e AS (SELECT DISTINCT json_extract_string(blk, '$.tool_use_id') AS id, coalesce(json_extract_string(blk, '$.content[0].text'), json_extract_string(blk, '$.content')) AS txt FROM b WHERE json_extract_string(blk, '$.type') = 'tool_result' AND json_extract_string(blk, '$.is_error') = 'true'),
i AS (SELECT left(string_split(string_split(txt, 'Invalid Input Error: ')[2], e'\n')[1], 60) AS msg FROM e WHERE contains(txt, 'Invalid Input Error'))
SELECT msg, len(list(msg)) AS n FROM i GROUP BY msg ORDER BY n DESC LIMIT 12;

-- 8. Sessions since Oct 9 ranked by dev MCP share (lowest first), 150+ file/shell/SQL calls.
WITH t AS (SELECT session_id, CASE WHEN starts_with(tool, 'dev.') THEN 'dev' WHEN tool = 'Bash' THEN 'bash' WHEN tool IN ('Read', 'Edit', 'Write') THEN 'native' END AS kind FROM agent.tool_calls WHERE ts >= TIMESTAMPTZ '2026-10-09'),
s AS (SELECT session_id, sum((kind = 'dev')::INT) AS dev, sum((kind = 'bash')::INT) AS bash, sum((kind = 'native')::INT) AS native FROM t GROUP BY session_id)
SELECT left(session_id, 8) AS session, dev, bash, native, round(100.0 * dev / (dev + bash + native), 0) AS dev_pct
FROM s WHERE dev + bash + native >= 150 ORDER BY dev_pct LIMIT 12;

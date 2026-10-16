-- Code-analysis recipes. Run LOAD separately, then one numbered SELECT at a time on dev MCP.
-- Verified 2026-10-16 against the installed extensions. Read-only: analyzed SQL is never executed.
-- parser_tools: https://github.com/hotdata-dev/duckdb_extension_parser_tools
-- sitting_duck: https://sitting-duck.readthedocs.io/en/latest/reference/functions/
-- duck_tails: https://duck-tails.readthedocs.io/en/latest/reference/diff/
LOAD parser_tools;
LOAD sitting_duck;
LOAD duck_tails;

-- 1. Validate SQL files without executing them
SELECT filename, is_parsable(content) AS valid,
       CASE WHEN is_parsable(content) THEN num_statements(content) END AS statements
FROM read_text('/Users/aloksubbarao/duckdb-skills/skills/self-dispatch/references/inline.sql');

-- 2. Inspect each statement and its scalar dispatch functions
WITH statements AS (
    SELECT filename, unnest(parse_statements(content)) AS sql
    FROM read_text('/Users/aloksubbarao/duckdb-skills/skills/self-dispatch/references/inline.sql')
    WHERE is_parsable(content)
)
SELECT filename, sql, parse_tables(sql) AS tables,
       list_filter(parse_functions(sql), f ->
           f.function_name IN ('tera_render', 'quackapi_post', 'http_post', 'http_post_form')) AS dispatch_functions
FROM statements;

-- 3. Locate actual dispatch call nodes, not every identifier token
SELECT file_path, name, type, start_line, end_line
FROM ast_select(
    '/Users/aloksubbarao/duckdb-skills/skills/self-dispatch/references/inline.sql',
    '.call#quackapi_post', 'sql')
ORDER BY start_line;

-- 4. Find reader calls inside SQL text held in rows
WITH programs AS (
    SELECT 'csv' AS label, $$SELECT * FROM read_csv('/tmp/a.csv', header := true)$$ AS sql
    UNION ALL
    SELECT 'json', $$SELECT * FROM read_json('/tmp/a.json')$$
), nodes AS (
    SELECT label, unnest(parse_ast_list(sql, 'sql'), recursive := true)
    FROM programs
)
SELECT label, name, type, start_line, end_line
FROM nodes
WHERE type = 'invocation' AND name IN ('read_csv', 'read_json');

-- 5. Inspect working-copy status, including new paths
SELECT repo_path, file_path, status, staged, unstaged
FROM git_status('/Users/aloksubbarao/duckdb-skills', untracked := true)
WHERE starts_with(file_path, 'skills/self-dispatch/')
ORDER BY file_path;

-- 6. Review a tracked file against HEAD
SELECT path1 AS before_path, path2 AS after_path,
       text_diff_stats(diff_text) AS changes, diff_text
FROM read_git_diff('/Users/aloksubbarao/duckdb-skills/server/replica/pull.sql');

-- 7. Review a new file as additions
SELECT path1 AS before_path, path2 AS after_path, diff_text
FROM read_git_diff('/dev/null',
    '/Users/aloksubbarao/duckdb-skills/skills/self-dispatch/references/find.sql.tera');

-- 8. Compose Duck Tails and Sitting Duck: calls and grammar errors in committed SQL
WITH selected_files AS (
    SELECT repo_path, file_path, git_uri, commit_hash
    FROM git_tree('/Users/aloksubbarao/duckdb-skills', 'HEAD')
    WHERE kind = 'file' AND file_path IN ('server/replica/pull.sql', 'server/replica/reads.sql')
), nodes AS (
    SELECT f.repo_path, f.file_path, f.commit_hash,
           unnest(parse_ast_list(r.text, 'sql'), recursive := true)
    FROM selected_files f
    CROSS JOIN LATERAL git_read_each(f.git_uri) r
)
SELECT repo_path, file_path, commit_hash, type, name, start_line, end_line
FROM nodes
WHERE type IN ('invocation', 'ERROR')
ORDER BY file_path, start_line;

-- Limits:
-- parser_tools validates syntax, not binding or execution. Its function facts omit FROM readers.
-- parse_statements normalizes SQL and removes comments; retain original text when comments matter.
-- Sitting Duck parses the outer language: SQL inside a string is not automatically parsed as SQL.
-- Tree-sitter SQL can emit ERROR nodes for valid DuckDB syntax. Empty matches do not prove absence.
-- On committed replica/pull.sql, quackapi_post was an identifier in an error subtree, not an invocation.
-- Recipe 8 keeps ERROR rows visible for that reason. Prefer parser_tools for DuckDB syntax validity.
-- Git status may collapse an untracked directory to one path. Do not label every file under a glob untracked.
-- Native diff calls are verified individually; UNION ALL of those calls lost Quack connections on this build.

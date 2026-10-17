-- Every dispatch site in duckdb-skills: which file posts statements, with which sender, on which lines.
-- Point the globs at any other repo. Tree-sitter misses some calls as invocations, so identifiers count too.
-- Read each site with the duckstack-review checks; the dispatched bodies are the $tag$ literals near it.
WITH files AS (
    SELECT filename, content FROM read_text(['/Users/aloksubbarao/duckdb-skills/server/*.sql', '/Users/aloksubbarao/duckdb-skills/skills/*/references/*.sql'])
), nodes AS (
    SELECT filename, unnest(parse_ast_list(content, 'sql'), recursive := true) FROM files
)
SELECT replace(filename, '/Users/aloksubbarao/duckdb-skills/', '') AS file, list(DISTINCT name) AS senders, list(DISTINCT start_line ORDER BY start_line) AS lines
FROM nodes WHERE type IN ('invocation', 'identifier') AND name IN ('selfdispatch', 'quackapi_post', 'http_post')
GROUP BY file ORDER BY file;

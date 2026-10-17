-- Actual dispatch review on codex/self-dispatch-review. One SELECT per dev MCP call.
-- Native parsing inspects SQL; none of the inspected programs are executed.
-- setup.sql contains extension parser syntax; replica/setup.sql includes .bail.
-- A false whole-file native parse or a tree-sitter ERROR is a finding to inspect, not proof of invalid DuckDB.
-- Identifier matches are candidates when the tree-sitter grammar cannot recognize a call.
-- Query 3 opens outer dollar-quoted bodies, including SQL stored in cron and boot posts.
-- Tera text must be rendered before it can be validated as SQL.

-- 1
WITH files AS (SELECT filename,content FROM read_text([
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/server/setup.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/server/replica/setup.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/server/replica/pull.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/server/replica/reads.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/skills/crawl/references/crawl_rows.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/skills/self-dispatch/references/inline.sql'
]))
SELECT filename,is_parsable(content) AS valid,
       CASE WHEN is_parsable(content) THEN num_statements(content) END AS statements
FROM files ORDER BY filename;

-- 2
WITH files AS (SELECT filename,content FROM read_text([
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/server/setup.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/server/replica/setup.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/server/replica/pull.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/server/replica/reads.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/skills/crawl/references/crawl_rows.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/skills/self-dispatch/references/inline.sql'
])), nodes AS (
    SELECT filename,unnest(parse_ast_list(content,'sql'),recursive:=true) FROM files
)
SELECT filename,type,name,start_line,end_line FROM nodes
WHERE type='ERROR'
   OR (type IN ('invocation','identifier') AND name IN ('selfdispatch','quackapi_post','http_post','http_post_form','tera_render'))
ORDER BY filename,start_line,type;

-- 3
WITH files AS (SELECT filename,content FROM read_text([
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/server/setup.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/server/replica/setup.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/server/replica/pull.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/server/replica/reads.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/skills/crawl/references/crawl_rows.sql',
    '/Users/aloksubbarao/worktrees/duckstack-self-dispatch-review/skills/self-dispatch/references/inline.sql'
])), nodes AS (
    SELECT filename,unnest(parse_ast_list(content,'sql'),recursive:=true) FROM files
), bodies AS (
    SELECT filename,start_line AS source_line,
           '$' || string_split(name,'$')[2] || '$' AS delimiter,
           substr(name,length(delimiter)+1,length(name)-2*length(delimiter)) AS sql
    FROM nodes WHERE type='literal' AND starts_with(name,'$')
), parsed AS (
    SELECT filename,source_line,sql,
           CASE WHEN is_parsable(sql) THEN parse_function_names(sql) END AS functions
    FROM bodies
)
SELECT filename,source_line,array_intersect(functions,['selfdispatch','quackapi_post','http_post','http_post_form']) AS senders,sql
FROM parsed WHERE len(senders)>0 ORDER BY filename,source_line;

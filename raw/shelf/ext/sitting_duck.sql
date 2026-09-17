-- @ext: sitting_duck
-- @rev: b8c06a8 (community, DuckDB 1.5.5 osx_arm64)
-- @verified: 2026-09-17 on inframe platform/backend (2,148 .py files, 182,259 named definitions, ~1 s)
-- @functions: read_ast, parse_ast, ast_select, is_definition, is_function_definition, is_class_definition, semantic_type_to_string, ast_supported_languages
-- @needs: nothing; squackit / pluckit / fledgling sit on top of it
-- @tags: ast, code search, callers, definitions, complexity, tree-sitter, css selector, who calls, refactor blast radius
-- @summary: Source code as a table of AST nodes with a semantic_type taxonomy. Definitions, calls,
--   scope and peek per node; CSS selectors for the common questions. 27 languages.
LOAD sitting_duck;

SELECT language, extensions FROM ast_supported_languages();

-- read_ast(files | glob | LIST, [language], ignore_errors := false, context := 'native', source := 'lines',
--          structure := 'full', peek := 'smart', max_depth := -1, prune := [...], batch_size := 1,
--          max_source_bytes, parse_timeout_ms, max_parse_nodes)
-- The cheap shape for a whole repo: definitions only, no peek.
CREATE TEMP TABLE defs AS
SELECT file_path, language, name, semantic_type, semantic_type_to_string(semantic_type) AS st, flags,
       start_line, end_line, descendant_count, scope
FROM read_ast(getenv('HOME') || '/inframe/platform/backend/app/**/*.py', ignore_errors := true, context := 'native', source := 'lines', peek := 'none')
WHERE is_definition(semantic_type) AND name IS NOT NULL;

-- Densest files ("functions" is a reserved word — quote the alias)
SELECT file_path,
       count(*) FILTER (WHERE is_function_definition(semantic_type)) AS "functions",
       count(*) FILTER (WHERE is_class_definition(semantic_type)) AS classes
FROM defs WHERE file_path NOT LIKE '%/tests/%' GROUP BY 1 ORDER BY 2 DESC LIMIT 20;

-- Where is X defined
SELECT file_path, name, start_line, end_line FROM defs WHERE name = 'run_migrations_online';

-- Who calls X (CSS selector: .call class, #name id). ast_select(source, selector) — the callers question that
-- reframed the migration bug: 9 migrations use autocommit_block(), every one releases the xact advisory lock.
SELECT file_path, start_line FROM ast_select(getenv('HOME') || '/inframe/platform/backend/app/alembic/versions/*.py', '.call#autocommit_block');

-- Methods vs free functions; enclosing scope comes with the row
SELECT name, scope.class AS class_name, scope.function AS enclosing_fn
FROM read_ast(getenv('HOME') || '/inframe/platform/backend/app/alembic/env.py') WHERE is_function_definition(semantic_type) OR is_call(semantic_type);

-- Inline code (literal only; parse_ast cannot take a column)
SELECT type, name, semantic_type_to_string(semantic_type) FROM parse_ast('def f(x): return g(x)', 'python');

-- Use semantic_type LIKE 'DEFINITION_%' (refinement-safe) rather than = 'DEFINITION_FUNCTION' (misses lambda/async/ctor).
-- squackit is the same engine with cached sessions:  squackit tool find "src/**/*.py" ".call#autocommit_block"

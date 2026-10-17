---
name: sitting-duck
description: Query source-code syntax trees and code structure with the sitting_duck DuckDB extension. Use for structural code search, function/call inventories and scope-aware analysis; not for Git history or CI log parsing.
---

# Sitting Duck

[Verified code-analysis queries](../query/references/code-analysis.sql) include
`ast_select(path, '.call#quackapi_post', 'sql')`, per-row `parse_ast_list`, and
committed-source reads through Duck Tails. Select invocation nodes rather than
counting their identifier children again. Keep ERROR nodes visible: the SQL grammar
can partially recover valid DuckDB syntax while missing calls within the error subtree.

Start with the [Sitting Duck documentation](https://sitting-duck.readthedocs.io/en/latest/).
Its function reference, output schema, parse-once/query-many guide and agent guide are
the relevant upstream sources for this skill. Add focused, verified recipes here as
real tasks establish useful patterns; do not copy the whole manual.

```sql
INSTALL sitting_duck FROM community;
LOAD sitting_duck;

SELECT name, type, semantic_type, start_line
FROM read_ast('src/**/*.py')
WHERE semantic_type = 'DEFINITION_FUNCTION'
  AND type = 'function_definition'
LIMIT 7;
```

Use `parse_ast(content, language)` for strings and `read_ast(path_or_glob)` for files.
Text held in a column needs full node text, but `parse_ast_list` cuts each peek at 80 characters. Route the
text through a ScalarFS path instead, never a temp file: `COPY (SELECT cmd ...) TO 'variable:cmd.sh'`, then
`read_ast('variable:cmd.sh', 'bash', peek := 'full')`. `read_ast` skips a path whose name has no parser
extension, even when the language is given, and fails with "needs at least one file to read". So name it
`cmd.sh` and never use a bare `data+varchar:` path (verified 2026-10-17, build 803b35b).

Inspect `duckdb_functions()` and `DESCRIBE` before assuming upstream fields or options
match the installed version. Scope source files before parsing; bound output previews
without confusing a result LIMIT with a parsing/resource limit.

For repeated analysis, store an AST relation only when re-parsing cost justifies it,
then apply downstream SQL to that relation. Retain source path, node identity and
locations so findings can be checked against the original code. Syntax/call analysis
is evidence about code structure, not proof of runtime reachability or dead code.
Semantic categories may also appear on child tokens; select actual definition nodes,
not every node sharing that category. Native node types vary by language.

Verified 2026-09-29 on dev: `parse_ast` of a small Python function returned its name,
node type, `DEFINITION_FUNCTION` semantic type and source line. This starter does not
claim validation of every language, selector or cross-file call-resolution feature.

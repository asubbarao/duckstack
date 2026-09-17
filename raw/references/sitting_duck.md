# sitting_duck (DuckDB community extension) — dense reference

Source of truth: clone at `<sitting_duck repo>` (docs + `src/`). Runtime could NOT be exercised
(community-extensions install blocked by proxy 403; no local build), so everything below is from reading the
source, the embedded SQL macros and the `test/sql` suite. Items marked **[unverified]** are inferred from code
paths, not observed.

Load: `INSTALL sitting_duck FROM community; LOAD sitting_duck;` (or `LOAD 'sitting_duck';` for a local build).
Pinned DuckDB: **v1.5.5** (`.github/workflows/MainDistributionPipeline.yml`: `DUCKDB_VERSION: v1.5.5`,
`DUCKDB_NEXT: v2.0-cyanoptera`; `duckdb/` submodule at `d8cdaa33fda8df955cc76ef58a280f68f4cd43fa`). Source carries
v2.0 compat shims (`Compat*` helpers), but the shipped/pinned target is 1.5.5.

---------------------------------------------------------------------------------------------------------------

## 1. Every function and macro (registered names, exact signatures)

Registration order (`src/sitting_duck_extension.cpp`): SEMANTIC_TYPE logical type -> `read_ast` family ->
`parse_ast` family -> `parse_ast_list` -> semantic type scalar functions -> `ast_supported_languages` ->
`ast_type_map` -> `register_language` -> SQL macros (12 embedded files, in this order:
`semantic_predicates.sql, file_utilities.sql, tree_navigation.sql, pattern_matching.sql, relational_operators.sql,
parse_ast_list_table.sql, css_selectors.sql, selector_for.sql, ast_select_rules.sql, scope_resolution.sql,
duck_blocks.sql, ast_patch.sql`) -> extension option -> pragma.
NOT registered (dead code): `read_ast_streaming`, `RegisterASTHelperFunctions` (ast_functions/ast_classes/
ast_imports BLOB-based table functions), `RegisterReadASTObjectsHybridFunction`.

### 1.1 Table functions (C++)

#### `read_ast(files [, language] , named...)`  — file/glob/list input, streaming
Overloads: `read_ast(ANY)` and `read_ast(ANY, VARCHAR)`. First arg must be `VARCHAR` or `LIST(VARCHAR)`
(else error `File patterns must be VARCHAR or LIST(VARCHAR)`). Errors: `File pattern list cannot be empty`,
`File pattern list cannot contain NULL values`, `Duplicate parameter name`, `read_ast needs at least one file to
read` (IOException, unless `ignore_errors`), `Could not detect language for file: <p>` (BinderException),
`Unsupported language: <l>`, `Failed to process <file>: <what>`, `Failed to initialize file processing: ...`.
Second positional `language` = NULL -> `'auto'`.

Named parameters (exact names and DuckDB types, `src/read_ast_streaming_function.cpp`):

| name | type | default | notes |
|---|---|---|---|
| `ignore_errors` | BOOLEAN | false | skips files that fail to read/parse/detect-language; empty file set -> 0 rows instead of error |
| `context` | VARCHAR | `'native'` | `'none' \| 'node_types_only' \| 'normalized' \| 'native'` (+`'+schema'`) |
| `source` | VARCHAR | `'lines'` | `'none' \| 'path' \| 'lines_only' \| 'lines' \| 'full'` (+`'+schema'`) |
| `structure` | VARCHAR | `'full'` | `'none' \| 'minimal' \| 'full'` (+`'+schema'`) |
| `peek` | ANY | `'smart'` | VARCHAR `'none' \| 'smart' \| 'full' \| 'custom' \| '<N>'` (+`'+schema'`), or INTEGER/BIGINT N (-> custom size N) |
| `peek_size` | INTEGER | 120 | legacy; only effective when peek mode is `custom` (see gotchas) |
| `peek_mode` | VARCHAR | `'smart'` | legacy alias of the VARCHAR form of `peek` |
| `batch_size` | INTEGER | 1 | files parsed per batch per thread; must be `> 0` (`batch_size must be positive`) |
| `max_depth` | INTEGER | -1 | -1 = unlimited; nodes deeper than N are dropped at parse time |
| `prune` | LIST(VARCHAR) | none | policies (lower-cased): `syntax, comments, literals, imports, types, punctuation, unnamed, leaves, internal`; unknown -> `Unknown prune policy` |
| `max_source_bytes` | BIGINT | 52428800 (50 MiB) | `<= 0` disables; over-limit -> `Refusing to read '<p>': file is N bytes, which exceeds max_source_bytes (...)` |
| `parse_timeout_ms` | BIGINT | 30000 | per-input tree-sitter timeout; `<= 0` disables |
| `max_parse_nodes` | BIGINT | 10000000 | per-input node cap; `<= 0` disables |

Prune policy semantics (`CompilePrunePolicy`): `syntax` = drop nodes with `IS_SYNTAX_ONLY` flag; `comments` =
drop `METADATA_COMMENT` nodes (re-parent children); `literals` = drop whole LITERAL-kind subtrees; `imports` = drop
whole EXTERNAL-kind subtrees; `types` = drop whole TYPE-kind subtrees; `punctuation` = drop `PARSER_PUNCTUATION`
nodes; `unnamed` = drop nodes with no name; `leaves` = drop leaf nodes; `internal` = drop internal nodes.

Siblings with same schema: `read_ast_flat` (same as `read_ast`), `read_ast_hierarchical` and
`read_ast_hierarchical_new` (STRUCT-packed columns `node_id, type, source, structure, context, peek`; legacy,
avoid).

#### `parse_ast(code VARCHAR, language VARCHAR, named...)` — inline string input
Named params: `context, source, structure, peek, max_source_bytes, parse_timeout_ms, max_parse_nodes` (NO
`ignore_errors`, `prune`, `max_depth`, `peek_size`, `peek_mode`, `batch_size`). `language` is required (no
auto-detect). Output schema identical to `read_ast`; `file_path = '<inline>'`. Only accepts **literal/constant**
arguments (table function, bound at bind time) — cannot be fed column values in a LATERAL. Siblings:
`parse_ast_flat`, `parse_ast_hierarchical`.

#### `parse_ast_list(code VARCHAR, language VARCHAR) -> LIST(STRUCT(...))` (SCALAR)
Column-valued friendly variant. STRUCT fields = full `read_ast` columns at default config but `semantic_type` is
plain `UTINYINT` (not SEMANTIC_TYPE), includes `receiver`, `scope`, `qualified_name`. Use
`unnest(parse_ast_list(col, 'python'))` or the table macro `parse_ast_list_table(code, language)` (projects
`node_id, type, name, qualified_name, start_line, end_line, parent_id, depth, sibling_index, children_count,
descendant_count, scope, peek, semantic_type, flags, signature_type, parameters, modifiers, annotations,
file_path, language` — note: no `receiver`, no column positions).

#### `ast_supported_languages()` -> `language VARCHAR, extensions LIST(VARCHAR), parser_type VARCHAR, node_type_count INTEGER`
`parser_type` = `'native'` for `duckdb`, `'tree-sitter'` otherwise.

#### `ast_type_map()` / `ast_type_map(language VARCHAR)` -> `language, node_type, semantic_type (SEMANTIC_TYPE), kind VARCHAR, name_role VARCHAR, is_scope BOOLEAN, is_syntax BOOLEAN, name_strategy VARCHAR, flags UTINYINT`
One row per (language, tree-sitter node type) in the built-in config tables. `kind` values: `definition, literal,
name, type, flow, error, external, statement, block, comment, pattern, operator, transform, access, syntax,
unknown`; `name_role`: `none|reference|declaration|definition`; `name_strategy`: `none, node_text, first_child,
find_identifier, find_property, find_assignment_target, find_qualified_identifier, find_in_declarator,
find_call_target, custom`.

#### `register_language(name VARCHAR, lib_path VARCHAR, config := VARCHAR, extensions := LIST(VARCHAR), aliases := LIST(VARCHAR), symbol := VARCHAR, overwrite := BOOLEAN)` -> `language, abi_version, node_type_count, status`
Loads a tree-sitter grammar shared library at runtime; requires `SET sitting_duck_enable_runtime_grammars = true`
(extension option, BOOLEAN default false). Default `symbol` = `tree_sitter_<name>`. `config` = JSON path with
per-node-type `semantic_type`, `refinement` (0-3), flags, name strategy.

#### Pragma `PRAGMA sitting_duck_enable_dynamic_predicates;`
Runs `CREATE OR REPLACE MACRO ast_dispatch_predicate(fn, node, arg) AS (apply(fn, node, arg)::BOOLEAN)`.

### 1.2 Scalar functions (C++, `src/semantic_type_functions.cpp`)

All take `UTINYINT` (SEMANTIC_TYPE and flags cast implicitly, cost 1).

| function | returns | semantics |
|---|---|---|
| `semantic_type_to_string(code)` | VARCHAR | name; refinement bits (low 2) masked when base name is known |
| `semantic_type_code(name VARCHAR)` | UTINYINT | NULL for unknown name |
| `get_super_kind(code)` | VARCHAR | `META_EXTERNAL / DATA_STRUCTURE / CONTROL_EFFECTS / COMPUTATION` (docs wrongly imply numeric) |
| `get_kind(code)` | VARCHAR | 16 kind names (`PARSER_SPECIFIC, RESERVED, METADATA, EXTERNAL, LITERAL, NAME, PATTERN, TYPE, OPERATOR, COMPUTATION_NODE, TRANSFORM, DEFINITION, EXECUTION, FLOW_CONTROL, ERROR_HANDLING, ORGANIZATION`) |
| `kind_code(name VARCHAR)` | UTINYINT | |
| `is_kind(code, kind_name VARCHAR)` | BOOLEAN | `(code & 0xF0) == kind` |
| `is_semantic_type(code, pattern VARCHAR)` | BOOLEAN | alias cascade on `code & 0xFC` (refinement-insensitive); see 4.5 for alias list; fallback exact full-name match |
| `is_definition(code)` | BOOLEAN | kind == DEFINITION |
| `is_call(code)` | BOOLEAN | `COMPUTATION_CALL` or `EXECUTION_STATEMENT_CALL` |
| `is_control_flow(code)` | BOOLEAN | kind == FLOW_CONTROL |
| `is_identifier(code)` | BOOLEAN | `NAME_IDENTIFIER`, `NAME_QUALIFIED`, `NAME_SCOPED` |
| `is_parser_specific(code)` | BOOLEAN | kind == PARSER_SPECIFIC |
| `is_punctuation(code)` | BOOLEAN | `PARSER_PUNCTUATION`/`PARSER_DELIMITER` |
| `get_searchable_types()` | LIST(UTINYINT) | `[DEFINITION_FUNCTION, DEFINITION_VARIABLE, DEFINITION_CLASS, DEFINITION_MODULE, COMPUTATION_CALL, COMPUTATION_ACCESS, EXTERNAL_IMPORT, EXTERNAL_EXPORT, FLOW_CONDITIONAL, FLOW_LOOP, FLOW_JUMP, ERROR_TRY, ERROR_CATCH, ERROR_THROW, NAME_IDENTIFIER, NAME_QUALIFIED]` |
| flags: `is_syntax_only(f)` | BOOLEAN | `f & 0x01` |
| `is_construct(f)` | BOOLEAN | NOT syntax-only (deprecated alias semantics) |
| `is_name_definition(f)` | BOOLEAN | `(f & 0x06) == 0x06` |
| `is_name_declaration(f)` | BOOLEAN | `(f & 0x06) == 0x04` |
| `is_name_reference(f)` | BOOLEAN | `(f & 0x06) == 0x02` |
| `binds_name(f)` | BOOLEAN | `f & 0x04` (declaration or definition) |
| `name_role(f)` | UTINYINT | `(f & 0x06) >> 1` -> 0 none,1 reference,2 declaration,3 definition |
| `is_scope(f)` | BOOLEAN | `f & 0x08` |
| `is_exported(f)` | BOOLEAN | `f & 0x10` |
| `is_constituent(f)` | BOOLEAN | `f & 0x20` |
| `is_declaration_only(f)` | BOOLEAN | name role == DECLARATION |
| `has_body(f)` / `is_embodied(f)` | BOOLEAN | name role == DEFINITION |
| `string_contains_any(str, LIST(VARCHAR))` | BOOLEAN | case-sensitive any-substring |
| `string_contains_any_i(str, LIST(VARCHAR))` | BOOLEAN | case-insensitive |
| `ast_peek_contains_any(str, LIST(VARCHAR))` | BOOLEAN | alias of `string_contains_any` |
| `detect_language(path VARCHAR)` | VARCHAR | by extension (case-insensitive, strips `scheme://`, leading `./`, trailing `@rev`); NULL if unknown |

### 1.3 SQL macros (all `CREATE OR REPLACE MACRO`; TABLE macros used in FROM)

**Argument convention (critical):** macros taking `source` / `path` / `file_patterns` call `read_ast(source, language)`
internally: pass a **path, glob or LIST of paths**, never a table name. Macros taking `ast_table` / `source`
resolved via `query_table(...)` take a **table/CTE name as a string** (`'my_ast'`). Table-name macros:
`ast_children, ast_call_arguments, ast_descendants, ast_ancestors, ast_siblings, ast_function_scope,
ast_class_members, ast_definition_parent, ast_select_from, ast_to_blocks_from, ast_selector_for, ast_patch(edits)`.

Scalar predicate macros (`semantic_predicates.sql`), all `(st)` -> BOOLEAN via `is_semantic_type`:
`is_function_definition, is_class_definition, is_variable_definition, is_module_definition, is_type_definition`
(**always false**: pattern `'DEFINITION_TYPE'` has no such name), `is_function_call` (COMPUTATION_CALL),
`is_member_access` (COMPUTATION_ACCESS), `is_string_literal, is_number_literal, is_boolean_literal` (**always
false**: `'LITERAL_BOOLEAN'` unknown; use `is_semantic_type(st,'BOOL')` -> LITERAL_ATOMIC), `is_literal`,
`is_conditional, is_loop, is_jump, is_block, is_list, is_assignment, is_comparison, is_arithmetic, is_logical,
is_import, is_export, is_foreign, is_comment, is_annotation, is_directive, is_type_primitive, is_type_composite,
is_type_reference, is_type_generic`.
`ast_qualified_name_as_string(qn)` -> VARCHAR like `C[User] F[__init__] V[x][2]` (prefix F/C/V/M/I/E, `[N]` index
suffix only when N>1; NULL for NULL/empty).

Tree navigation (`tree_navigation.sql`):

| macro | args | output |
|---|---|---|
| `ast_children(ast_table, parent_node_id)` | table name, id | `SELECT *` rows where `parent_id = id` |
| `ast_call_arguments(ast_table, call_node_id)` | | `arg_position, arg_node_id, arg_name, arg_type, arg_peek, semantic_type, start_line, end_line` (children of `argument_list|arguments|actual_parameters`, excluding `( ) , comment`) |
| `ast_descendants(ast_table, ancestor_node_id)` | | subtree rows via `node_id > a AND node_id <= a + descendant_count` |
| `ast_ancestors(ast_table, child_node_id)` | | recursive up `parent_id`, includes the node itself |
| `ast_siblings(ast_table, target_node_id)` | | same parent, excluding self |
| `ast_function_scope(ast_table, func_node_id)` | | descendants excluding nested function bodies |
| `ast_class_members(ast_table, class_node_id)` | | `node_id, descendant_count, name, type, semantic_type, start_line, end_line, depth, parent_id, peek, file_path, language` of direct member definitions |
| `ast_definition_parent(ast_table)` | | `node_id, def_name, kind, parent_def_name, parent_def_kind, parent_def_node_id` (nearest enclosing definition, <=10 hops) |
| `ast_definitions(source, language := NULL)` | path/glob | `name, definition_type ('function'\|'class'\|'variable'\|'module'\|'type'\|'other'), language, file_path, start_line, end_line, node_id, type, semantic_type`; filter `is_definition AND is_construct(flags) AND name != ''` |
| `ast_resolve_entity(path, entity_name, kind := NULL, language := NULL)` | | `name, entity_kind, start_line, end_line, qualified_name (string form), language, file_path` (undocumented in docs) |
| `ast_containing_line(source, line_num, language := NULL)` | | all columns; nodes spanning the line, smallest span first |
| `ast_in_range(source, range_start, range_end, language := NULL)` | | all columns; nodes fully inside the range |
| `ast_function_metrics(source, language := NULL)` | | `file_path, name, language, start_line, end_line, lines, return_count, conditionals, loops, cyclomatic (= conditionals+loops+1), max_depth` (nested fn bodies excluded) |
| `ast_functions_containing(source, target_type, language := NULL)` | tree-sitter type | `file_path, func_name, language, func_start_line, func_end_line, match_name, match_line, match_peek` |
| `ast_nesting_analysis(source, language := NULL)` | | `file_path, name, language, start_line, end_line, max_depth, avg_depth, deep_nodes (>5), total_nodes` |
| `ast_security_audit(source, language := NULL)` | | `file_path, language, start_line, function_name, risk_category, risk_level ('high'\|'medium'\|'low'), finding, matched_pattern, context`; pattern names: eval exec compile Function setInterval setTimeout system popen spawn execSync execFile ShellExecute pickle.load pickle.loads yaml.load unserialize Marshal.load readObject execute executemany raw rawQuery readFile writeFile unlink rmdir md5 sha1 DES RC4 console.log print debugger assert (matches on call name, `%.name`, `name.%`, or peek LIKE) |
| `ast_dead_code(source, language := NULL)` | | `file_path, name, language, start_line, end_line, type, definition_type, reason`; heuristic (name never appears as call or identifier ref); skips `__x`, main/setup/teardown/init/constructor |
| `ast_get_calls(source, language := NULL)` | | `file_path, caller_name ('<module>' if none), called_name, call_expression (peek), call_type ('constructor'\|'macro'\|'method'\|'function'), language, start_line, node_id, caller_node_id` |
| `ast_call_graph(source, language := NULL)` | | `file_path, caller, callee, call_type, call_count` |

Scope resolution (`scope_resolution.sql`), all path/glob `source`, `language := NULL`:

| macro | output |
|---|---|
| `ast_exports(source)` | all columns; `is_name_definition(flags) AND is_exported(flags) AND COALESCE(scope.current,0)=0` |
| `ast_imports(source)` | `file_path, source_module, imported_name, import_type, start_line` |
| `ast_resolve(source)` | `ref_node_id, ref_name, ref_type, ref_line, file_path, def_node_id, def_type, def_line, def_qualified_name, scope_hops` |
| `ast_callees(source)` | `caller, caller_qualified, caller_line, file_path, callee, callee_line, call_peek` (uses `c.semantic_type = 'COMPUTATION_CALL'`, join on `scope.function`) |
| `ast_callers(source)` | `caller ('<module>'), caller_line (0), callee, call_line, file_path` |
| `ast_find_references(source, target_name)` | `file_path, name, ref_kind ('definition'\|'call'\|'reference'), node_type, start_line, peek, scope_name, def_node_id` |

Relational operators (`relational_operators.sql`), path `source`, all return full `read_ast` rows of the first type:
`ast_has(source, ancestor_type, descendant_type, descendant_name := NULL, language := NULL)` (ancestors that
contain a descendant), `ast_not_has(...)` same args, `ast_inside(source, descendant_type, ancestor_type,
ancestor_name := NULL, descendant_name := NULL, language := NULL)`, `ast_precedes(source, node_type, before_type,
before_name := NULL, language := NULL)`, `ast_follows(source, node_type, after_type, after_name := NULL,
language := NULL)`. Types are tree-sitter `type` strings.

CSS selectors (`css_selectors.sql`):
- `ast_select(source, selector, language := NULL)` — parses with
  `read_ast(source, language, peek := CASE WHEN selector LIKE '%[peek%' THEN 'full' ELSE 'none+schema' END)` then
  delegates. **=> `peek` column is present but NULL unless the selector contains `[peek`**.
- `ast_select_from(source_table_name, selector)` — engine over a pre-parsed table (`query_table`). Returns all
  columns of that table, `ORDER BY file_path, node_id`.
- `ast_selector_for(source_table_name, target_file, target_node_id)` — "copy selector": candidate selectors ranked
  (strategies `class_name .fn#load`, `type_name function_definition#load`, `receiver .call#execute[receiver="db"]`,
  `in_function`, `in_class`, `location call#execute[file$="app.py"][line=42]`) with a `matches` count. Errors if
  the node is not in the table.
- `ast_select_rules(source, query, language := NULL)` / `ast_select_list(...)` — multi-rule CSS query; **WIP,
  crashes at bind time** on DuckDB 1.5.x (`INTERNAL Error: Failed to bind column reference`, duckdb/duckdb#21890).
  Do not use.

Pattern matching (`pattern_matching.sql`):
- `ast_match(source, pattern_str, language := 'python', match_syntax := false, match_by := 'type', depth_fuzz := 0)`
  — path/glob source (**default language is `'python'`**, used for both files and pattern parsing). Output:
  `match_id, root_node_id, file_path, start_line, end_line, peek, captures` where `captures` is
  `MAP(VARCHAR, LIST(STRUCT(capture, node_id, type, name, peek, start_line, end_line)))`.
- `ast_capture(captures_map, capture_name)` = `captures_map[capture_name][1]`.
- Helpers (public but internal): `ast_pattern(pattern_str, language)` (table), `ast_pattern_list(pattern_str,
  language)`, `clean_pattern`, `pattern_has_variadic`, `pattern_has_recursive`, `is_pattern_wildcard`,
  `wildcard_capture_name`, `semantic_type_base`, `parse_html_wildcard`.

Source utilities (`file_utilities.sql`):
- scalar `ast_get_source(file_path, start_line, end_line)` -> VARCHAR (raw lines joined), `ast_get_source_numbered(...)`
  (`%4d: line`), `ast_get_source_line(file_path, line_num)`; all use `read_text(file_path)` (literal path).
- table `ast_source_of(file_patterns, target_name, language := NULL, kind := NULL)` -> `file_path, name,
  definition_kind, start_line, end_line, source` (numbered source of every definition named `target_name`; `kind`
  in `'function'|'class'|'variable'|'module'|'type'`).

Patching (`ast_patch.sql`):
- scalar `ast_node_edit(node, edit_kind, new_text)` -> STRUCT `{file_path, start_line, start_column, end_line,
  end_column, edit_kind, new_text}`; pass a `read_ast(..., source := 'full') r` row alias as `node`, expand with
  `unnest(...)`.
- table `ast_patch(edits_table_name, files)` -> `file_path, patched_source` (pure; writes nothing). `edit_kind` in
  `'replace'|'delete'|'insert_before'|'insert_after'`. Columns are 1-indexed; `end_column` is EXCLUSIVE byte
  offset. Errors on: unknown kind, NULL positions (needs `source := 'full'`, and `parse_ast` rows cannot be patched
  because `file_path='<inline>'`), file not covered by `files`, out-of-range positions (staleness guard),
  overlapping edits.
- table `ast_replace(source, selector, new_text, language := NULL)` -> same as `ast_patch`; selector via
  `ast_select_from`; literal replacement only. Write back with
  `COPY (SELECT patched_source FROM ast_patch('edits','src/main.py')) TO 'src/main.py' (FORMAT csv, QUOTE '', ESCAPE '', HEADER false);`

Duck blocks (`duck_blocks.sql`):
- `ast_to_blocks(source, language := NULL, style := 'outline', include_bodies := true, include_metadata := true,
  base_heading_level := 1, max_heading_level := 6)` -> `file_path, element_order, block STRUCT(kind, element_type,
  content, level, encoding, attributes MAP(VARCHAR,VARCHAR), element_order)`; parses with `peek := 'full'`.
- `ast_to_blocks_from(source_table_name, style..., ...)` — engine; errors if table has no peek text.
- `ast_to_blocks_list(source, ...)` -> `file_path, blocks LIST(block)`. Render with duck_block_utils:
  `SELECT db_render_blocks(blocks) FROM ast_to_blocks_list('src/main.py');`

---------------------------------------------------------------------------------------------------------------

## 2. Output schema, semantic_type taxonomy, flags, extraction levels

### 2.1 `read_ast` / `parse_ast` columns (default config), in order

| column | type | present when | meaning |
|---|---|---|---|
| `node_id` | BIGINT | always | DFS pre-order index, 0-based **per file** (root = 0). Not unique across files |
| `type` | VARCHAR | always | tree-sitter node type (`function_definition`, `call`, `identifier`, `ERROR`...) |
| `semantic_type` | SEMANTIC_TYPE (UTINYINT alias) | context >= node_types_only | 8-bit code, displays as name |
| `flags` | UTINYINT | context >= node_types_only | bitfield (2.3) |
| `name` | VARCHAR | context >= normalized | extracted name (NULL/'' when none) |
| `qualified_name` | LIST(STRUCT(semantic_type SEMANTIC_TYPE, name VARCHAR, index INTEGER)) | context >= normalized | scope path outermost->innermost, `index` disambiguates repeated names |
| `signature_type` | VARCHAR | context = native | return type / declared type |
| `parameters` | LIST(STRUCT(name VARCHAR, type VARCHAR)) | native | |
| `modifiers` | LIST(VARCHAR) | native | e.g. `static, virtual, const, override, final, async, public, private, protected, inline, explicit, constexpr, noexcept, extern, friend, template` |
| `annotations` | VARCHAR | native | decorators/attributes text |
| `receiver` | VARCHAR | native | object a method is invoked on (`con.execute()` -> `con`); NULL for bare calls / ambiguous chains (**undocumented in docs**) |
| `file_path` | VARCHAR | source != none | `'<inline>'` for parse_ast |
| `language` | VARCHAR | source != none | canonical language name |
| `start_line`, `end_line` | UINTEGER | source >= lines_only | 1-indexed, inclusive |
| `start_column`, `end_column` | UINTEGER | source = full | 1-indexed BYTE offsets; `end_column` exclusive |
| `parent_id` | BIGINT | structure >= minimal | NULL for root |
| `depth` | UINTEGER | structure >= minimal | root = 0 |
| `sibling_index` | INTEGER | structure = full | 0-based (docs say UINTEGER/minimal; source: INTEGER, full only) |
| `children_count` | UINTEGER | structure = full | direct children |
| `descendant_count` | UINTEGER | structure = full | size of subtree excluding self |
| `scope` | STRUCT(current BIGINT, function BIGINT, class BIGINT, module BIGINT, stack LIST(STRUCT(id BIGINT, kind SEMANTIC_TYPE))) | structure = full | nearest enclosing scope ids (on every node); `stack` (outermost first) only on scope nodes; module-level -> `current` NULL/0 |
| `peek` | VARCHAR | peek != none | source preview; NULL when empty |

`+schema` suffix on any level value keeps ALL columns in the schema (populated ones filled, the rest NULL) so
`SELECT *`/UNION shapes are stable, e.g. `context := 'none+schema'`, `peek := 'none+schema'`.

Peek modes (`unified_ast_backend_impl.hpp`): `none` -> NULL; `full` -> complete node text; `smart` -> full text if
<= 50 chars, else single-line text truncated to 77 chars + `...` if > 80, else first line (same 80/77 rule);
numeric N / `custom` -> first N chars (N=0 -> NULL, N=-1 -> full). Peek is sanitized UTF-8. Smart peek NEVER
exceeds 80 chars regardless of `peek_size`.

### 2.2 semantic_type: 8-bit `[ss kk tt ll]`
Super kind = bits 7-6, kind = bits 5-4, super type = bits 3-2, refinement (language-specific) = bits 1-0.
Helpers: `GetSuperKind = & 0xC0`, `GetKind = & 0xF0`, base type = `& 0xFC`.

Super kinds: `META_EXTERNAL 0x00`, `DATA_STRUCTURE 0x40`, `CONTROL_EFFECTS 0x80`, `COMPUTATION 0xC0`.
Kinds: `PARSER_SPECIFIC 0x00, RESERVED 0x10, METADATA 0x20, EXTERNAL 0x30, LITERAL 0x40, NAME 0x50, PATTERN 0x60,
TYPE 0x70, EXECUTION 0x80, FLOW_CONTROL 0x90, ERROR_HANDLING 0xA0, ORGANIZATION 0xB0, OPERATOR 0xC0,
COMPUTATION_NODE 0xD0, TRANSFORM 0xE0, DEFINITION 0xF0`.

Full base-type table (decimal = hex; name as returned by `semantic_type_to_string`):

| dec | hex | name |
|---|---|---|
| 0 | 0x00 | PARSER_CONSTRUCT |
| 4 | 0x04 | PARSER_DELIMITER |
| 8 | 0x08 | PARSER_PUNCTUATION |
| 12 | 0x0C | PARSER_SYNTAX |
| 16..28 | 0x10-0x1C | RESERVED_* (unused) |
| 32 | 0x20 | METADATA_COMMENT |
| 36 | 0x24 | METADATA_ANNOTATION |
| 40 | 0x28 | METADATA_DIRECTIVE |
| 44 | 0x2C | METADATA_DEBUG |
| 48 | 0x30 | EXTERNAL_IMPORT |
| 52 | 0x34 | EXTERNAL_EXPORT |
| 56 | 0x38 | EXTERNAL_FOREIGN |
| 60 | 0x3C | EXTERNAL_EMBED |
| 64 | 0x40 | LITERAL_NUMBER |
| 68 | 0x44 | LITERAL_STRING |
| 72 | 0x48 | LITERAL_ATOMIC (true/false/null/None) |
| 76 | 0x4C | LITERAL_STRUCTURED (arrays/objects) |
| 80 | 0x50 | NAME_IDENTIFIER |
| 84 | 0x54 | NAME_QUALIFIED |
| 88 | 0x58 | NAME_SCOPED (this/self/::) |
| 92 | 0x5C | NAME_ATTRIBUTE |
| 96 | 0x60 | PATTERN_DESTRUCTURE |
| 100 | 0x64 | PATTERN_COLLECT |
| 104 | 0x68 | PATTERN_TEMPLATE |
| 108 | 0x6C | PATTERN_MATCH |
| 112 | 0x70 | TYPE_PRIMITIVE |
| 116 | 0x74 | TYPE_COMPOSITE |
| 120 | 0x78 | TYPE_REFERENCE |
| 124 | 0x7C | TYPE_GENERIC |
| 128 | 0x80 | EXECUTION_STATEMENT |
| 132 | 0x84 | EXECUTION_DECLARATION |
| 136 | 0x88 | EXECUTION_STATEMENT_CALL (docs call it EXECUTION_INVOCATION) |
| 140 | 0x8C | EXECUTION_MUTATION |
| 144 | 0x90 | FLOW_CONDITIONAL |
| 148 | 0x94 | FLOW_LOOP |
| 152 | 0x98 | FLOW_JUMP |
| 156 | 0x9C | FLOW_SYNC |
| 160 | 0xA0 | ERROR_TRY |
| 164 | 0xA4 | ERROR_CATCH |
| 168 | 0xA8 | ERROR_THROW |
| 172 | 0xAC | ERROR_FINALLY |
| 176 | 0xB0 | ORGANIZATION_BLOCK |
| 180 | 0xB4 | ORGANIZATION_LIST (argument/parameter lists) |
| 184 | 0xB8 | ORGANIZATION_SECTION |
| 188 | 0xBC | ORGANIZATION_CONTAINER (file roots: module/program/source_file) |
| 192 | 0xC0 | OPERATOR_ARITHMETIC |
| 196 | 0xC4 | OPERATOR_LOGICAL |
| 200 | 0xC8 | OPERATOR_COMPARISON |
| 204 | 0xCC | OPERATOR_ASSIGNMENT |
| 208 | 0xD0 | COMPUTATION_CALL |
| 212 | 0xD4 | COMPUTATION_ACCESS (member access / subscript) |
| 216 | 0xD8 | COMPUTATION_EXPRESSION |
| 220 | 0xDC | COMPUTATION_CLOSURE (docs call it COMPUTATION_LAMBDA) |
| 224 | 0xE0 | TRANSFORM_QUERY (comprehensions, SQL queries) |
| 228 | 0xE4 | TRANSFORM_ITERATION |
| 232 | 0xE8 | TRANSFORM_PROJECTION |
| 236 | 0xEC | TRANSFORM_AGGREGATION |
| 240 | 0xF0 | DEFINITION_FUNCTION |
| 244 | 0xF4 | DEFINITION_VARIABLE |
| 248 | 0xF8 | DEFINITION_CLASS (also struct/interface/enum/typedef/type alias) |
| 252 | 0xFC | DEFINITION_MODULE (named module/namespace/package definitions) |

Refinements (low 2 bits, `SemanticRefinements::`), widely populated by the built-in `.def` tables (805 uses):
Function `REGULAR 0 / LAMBDA 1 / CONSTRUCTOR 2 / ASYNC 3` (Python `lambda`=241, `async_function_definition`=243;
JS `arrow_function`/`function_expression`=241, `constructor`=242, async/generator=243; C++ `lambda_expression`=241,
`constructor_definition`/`destructor_definition`=242); Variable `MUTABLE 0 / IMMUTABLE 1 / PARAMETER 2 / FIELD 3`;
Class `REGULAR 0 / ABSTRACT 1 / GENERIC 2 / ENUM 3`; Call `FUNCTION 0 / METHOD 1 / CONSTRUCTOR 2 / MACRO 3`
(JS/TS/C++ `new_expression`=210, C `preproc_call`=211, Rust `method_call_expression`=209, `macro_invocation`=211);
Number `INTEGER/FLOAT/SCIENTIFIC/COMPLEX`; Structured `GENERIC/SEQUENCE/MAPPING/SET`; Arithmetic
`BINARY/UNARY/BITWISE/RANGE`; Conditional `BINARY/MULTIWAY/GUARD/TERNARY`; Loop `COUNTER/ITERATOR/CONDITIONAL/
INFINITE`; Organization `SEQUENTIAL/COLLECTION/MAPPING/HIERARCHICAL`; Import `MODULE/SELECTIVE/WILDCARD/RELATIVE`;
String `LITERAL/TEMPLATE/REGEX/RAW`; Comparison `EQUALITY/RELATIONAL/MEMBERSHIP/PATTERN`; Assignment
`SIMPLE/COMPOUND/DESTRUCTURE/AUGMENTED`.

**Comparing semantic_type to a string.** Casts: `SEMANTIC_TYPE -> VARCHAR` (cost 1, masks refinement bits so
241 prints `DEFINITION_FUNCTION`) and `VARCHAR -> SEMANTIC_TYPE` (exact code of the base name, e.g. 240).
`WHERE semantic_type = 'DEFINITION_FUNCTION'` is the documented idiom. **[unverified]** By DuckDB's max-type rule the
literal is cast to SEMANTIC_TYPE (240) and compared as UTINYINT, which would MISS refined variants (lambda 241,
async 243, constructors 242; `new_expression` 210 for `= 'COMPUTATION_CALL'`). Refinement-safe alternatives, all
mask to `& 0xFC`: `is_semantic_type(semantic_type, 'DEFINITION_FUNCTION')`, `is_function_definition(semantic_type)`,
`semantic_type_to_string(semantic_type) = 'DEFINITION_FUNCTION'`, `semantic_type::VARCHAR = '...'`,
`(semantic_type::UTINYINT & 252) = 240`, or CSS `.func`/`.call`. Prefer these in real analyses.

### 2.3 `flags` bitfield (`src/include/node_config.hpp`)

| bit | mask | name | predicate |
|---|---|---|---|
| 0 | 0x01 | IS_SYNTAX_ONLY (keywords, punctuation; they inherit the parent's semantic_type!) | `is_syntax_only` |
| 1-2 | 0x06 | NAME_ROLE: 0x00 NONE, 0x02 REFERENCE, 0x04 DECLARATION (no body), 0x06 DEFINITION (with body) | `is_name_reference / is_name_declaration / is_name_definition / binds_name (0x04) / name_role` |
| 3 | 0x08 | IS_SCOPE (creates scope boundary) | `is_scope` |
| 4 | 0x10 | IS_EXPORTED (set on name-binding nodes the adapter deems public; Python: not `_`-prefixed) | `is_exported` |
| 5 | 0x20 | IS_CONSTITUENT (meaningful sub-part, e.g. import specifier) | `is_constituent` |

The flag table in `docs/reference/semantic-types.md` (IS_KEYWORD/IS_PUBLIC/IS_UNSAFE... ) is stale; the above is
the code.

Keyword tokens (`def`, `class`, `CREATE`...) carry the SAME semantic_type as their construct with
`IS_SYNTAX_ONLY` set. **Always** filter definitions with `is_definition(semantic_type) AND NOT
is_syntax_only(flags) AND name != ''` (or `is_construct(flags)`), otherwise every definition is duplicated by its
keyword.

### 2.4 Extraction levels and cost

| param | value | adds | cost |
|---|---|---|---|
| `context` | `none` | node_id, type only | cheapest |
| | `node_types_only` | + semantic_type, flags | table lookup |
| | `normalized` | + name, qualified_name | name extraction per node |
| | `native` (default) | + signature_type, parameters, modifiers, annotations, receiver | per-language extractors |
| `source` | `none` / `path` (file_path, language) / `lines_only` / `lines` (default) / `full` (+columns) | | columns needed for `ast_patch`/`ast_replace` |
| `structure` | `none` / `minimal` (parent_id, depth) / `full` (default: + sibling_index, children_count, descendant_count, scope) | | full needed for subtree math, `scope`, CSS combinators |
| `peek` | `none` / `smart` (default) / `full` / N | | `full` copies each node's whole text: O(file_size x depth) per file; the expensive part of extraction |

Languages WITHOUT native extractors (signature_type/parameters/modifiers/annotations stay NULL, names still
extracted): `duckdb, graphql, hcl, json, lua, markdown, toml, zig` (no `*_native_extractors.hpp`). With native
extractors: `bash, c, cpp, csharp, css, dart, go, html, java, javascript, kotlin, php, python, r, ruby, rust, sql,
swift, typescript`.

---------------------------------------------------------------------------------------------------------------

## 3. Languages, `language :=` strings, auto-detection

27 built-ins (`cmake/BuiltinLanguages.cmake`). Canonical name -> accepted aliases (case-sensitive as listed;
`r` also accepts `R`):

`python` {python, py} · `javascript` {javascript, js} · `typescript` {typescript, ts} · `cpp` {cpp, c++, cxx, cc} ·
`c` {c} · `sql` {sql} · `duckdb` {duckdb, duckdb-sql} (native DuckDB parser, `parser_type='native'`) ·
`go` {go, golang} · `ruby` {ruby, rb} · `markdown` {markdown, md} · `java` {java} · `php` {php} · `html` {html, htm} ·
`css` {css} · `rust` {rust, rs} · `json` {json} · `bash` {bash, shell, sh} · `swift` {swift} · `r` {r, R} ·
`kotlin` {kotlin, kt} · `csharp` {csharp, cs, c#} · `lua` {lua} · `hcl` {hcl, terraform, tf, tfvars} ·
`graphql` {graphql, gql} · `toml` {toml} · `zig` {zig} · `dart` {dart}.
A `yaml` adapter exists in source but is NOT in the built-in list (grammar commented out in CMake); docs mention
YAML/Scala/F#/Haskell/Julia — not built.

Extension map (`src/ast_file_utils.cpp`, case-insensitive): `.h -> c` (NOT cpp); `.hpp .hh .hxx .h++ .cpp .cc .cxx
.c++ -> cpp`; `.c -> c`; `.py .pyi .pyw -> python`; `.js .jsx .mjs -> javascript`; `.ts .tsx -> typescript`;
`.go`; `.rb .ruby -> ruby`; `.sql -> sql` (never `duckdb`; `duckdb` has NO extension, must be explicit);
`.rs .rlib -> rust`; `.md .markdown -> markdown`; `.java`; `.php .php3 .php4 .php5 .phtml -> php`; `.html .htm`;
`.css`; `.json`; `.sh .bash .zsh -> bash`; `.swift`; `.r .R -> r`; `.kt .kts -> kotlin`; `.cs -> csharp`; `.lua`;
`.hcl .tf .tfvars -> hcl`; `.graphql .gql -> graphql`; `.toml`; `.zig`; `.dart`. No `.yml/.yaml`, no `.cjs`,
`.mts`, `.cts`, `.vue`, `.svelte`, `.Makefile`, `.txt`, `.cmake`, `.def`.

File resolution (`ASTFileUtils::GetFiles`): each pattern -> if it has a URI scheme (`xxx://`) pass straight to the
DuckDB VFS (this is how `git://path@rev` from duck_tails works; extension detection strips scheme, `./`, `@rev`);
else if an existing file -> itself; if a directory -> `dir/*`; else glob via `fs.Glob`. Results concatenated,
**sorted and de-duplicated**. When `language` is explicit (not auto), files whose extension is not in that
language's extension list are **filtered out** — so `read_ast('script.txt', 'python')`, `read_ast('Makefile',
'bash')`, `read_ast('actually_python.js', 'python')` all yield "read_ast needs at least one file to read" (IO
Error; confirmed by `test/sql/core/error_handling.test`). Explicit language is an extension filter, not an
override. To parse an extensionless/odd file: `SELECT * FROM parse_ast((SELECT content FROM read_text('Makefile')), 'bash')`
does NOT work either (parse_ast needs literal args) — use `unnest(parse_ast_list(content, 'bash'))` from `read_text`.

Auto-detection with `ignore_errors := false` errors on the first unknown extension (`Could not detect language for
file`); with `ignore_errors := true` such files are skipped. Tree-sitter syntax errors do NOT raise: they appear as
nodes with `type = 'ERROR'` (and `MISSING`), the file still yields rows.

---------------------------------------------------------------------------------------------------------------

## 4. Queries

### 4.1 `docs/how-to/common-queries.md` (verbatim, with intents)

```sql
-- all function definitions in a file
SELECT name, start_line, end_line FROM read_ast('test/data/python/sample_app.py') WHERE semantic_type = 'DEFINITION_FUNCTION';
-- same via CSS: semantic class + :definition
SELECT name, start_line, end_line FROM ast_select('test/data/python/sample_app.py', '.func:definition');
-- classes with subtree size as rough complexity
SELECT name, start_line, descendant_count FROM read_ast('test/data/python/sample_app.py') WHERE semantic_type = 'DEFINITION_CLASS';
-- one definition by name (#name selector)
SELECT * FROM ast_select('test/data/python/sample_app.py', 'function_definition#validate_email');
-- all named definitions of any kind
SELECT name, semantic_type, start_line FROM read_ast('test/data/python/sample_app.py') WHERE semantic_type LIKE 'DEFINITION_%' AND name IS NOT NULL;
-- direct children of a class (raw SQL)
WITH cls AS (SELECT node_id FROM read_ast('test/data/python/sample_app.py') WHERE type = 'class_definition' AND name = 'UserService')
SELECT type, name, start_line FROM read_ast('test/data/python/sample_app.py') WHERE parent_id = (SELECT node_id FROM cls);
-- same with child combinator
SELECT name FROM ast_select('test/data/python/sample_app.py', 'class_definition#UserService > function_definition');
-- functions anywhere inside a class (descendant combinator)
SELECT name FROM ast_select('test/data/python/sample_app.py', 'class_definition#DatabaseConnection function_definition');
-- deeply nested nodes
SELECT type, name, depth, start_line FROM read_ast('test/data/python/sample_app.py') WHERE depth > 5 ORDER BY depth DESC;
-- enclosing function of each call via scope struct (no join)
SELECT name, scope.function AS enclosing_fn FROM read_ast('test/data/python/sample_app.py') WHERE semantic_type = 'COMPUTATION_CALL';
-- methods vs top-level functions
SELECT name, scope.class FROM read_ast('test/data/python/sample_app.py') WHERE semantic_type = 'DEFINITION_FUNCTION' AND scope.class IS NOT NULL;
SELECT name, start_line FROM read_ast('test/data/python/sample_app.py') WHERE semantic_type = 'DEFINITION_FUNCTION' AND scope.class IS NULL AND scope.function IS NULL;
-- signatures via peek
SELECT name, peek FROM read_ast('test/data/python/sample_app.py') WHERE semantic_type = 'DEFINITION_FUNCTION';
-- docs claim longer peek via peek_size (does NOT work in smart mode; use peek := 500) and peek_mode := 'smart'
SELECT name, peek FROM read_ast('test/data/python/sample_app.py', peek_size := 500) WHERE semantic_type = 'DEFINITION_FUNCTION';
SELECT name, peek FROM read_ast('test/data/python/sample_app.py', peek_mode := 'smart') WHERE semantic_type = 'DEFINITION_CLASS';
-- cross-file glob
SELECT file_path, name, start_line FROM read_ast('src/**/*.py') WHERE semantic_type = 'DEFINITION_FUNCTION';
SELECT file_path, name FROM ast_select('src/**/*.py', '.class:definition');
-- densest files
SELECT file_path, COUNT(*) AS defs FROM read_ast('src/**/*.py') WHERE semantic_type LIKE 'DEFINITION_%' GROUP BY file_path ORDER BY defs DESC;
-- robust scan
SELECT file_path, COUNT(*) AS nodes FROM read_ast('src/**/*.*', ignore_errors := true) GROUP BY file_path;
```
Note `semantic_type LIKE 'DEFINITION_%'` forces the column to VARCHAR (refinement-safe), while `= '...'` does not.

### 4.2 `docs/tutorials/ai-agents.md` (all queries, intents inline)

```sql
-- distribution of semantic types with readable names
SELECT semantic_type_to_string(semantic_type) AS type_name, get_super_kind(semantic_type) AS category, COUNT(*) AS count
FROM read_ast('main.py') GROUP BY semantic_type ORDER BY count DESC;
-- complex functions via predicates
SELECT name, file_path, descendant_count FROM read_ast('**/*.py', ignore_errors := true)
WHERE is_definition(semantic_type) AND semantic_type_to_string(semantic_type) = 'DEFINITION_FUNCTION' AND descendant_count > 50;
-- pattern arrays (deduplicated, sorted by path)
SELECT * FROM read_ast('src/**/*.py');
SELECT * FROM read_ast(['src/**/*.py', 'lib/**/*.js', 'tests/**/*.ts']);
SELECT * FROM read_ast(['main.py', 'src/**/*.js', 'specific_file.cpp']);
SELECT * FROM read_ast([]);              -- Error: File pattern list cannot be empty
SELECT * FROM read_ast(['file.py', NULL]); -- Error: File pattern list cannot contain NULL values
-- files processed per language (note: counts NODES, not files, despite the alias)
SELECT language, COUNT(*) AS files_processed
FROM read_ast(['src/**/*.py','frontend/**/*.js','backend/**/*.ts','native/**/*.cpp','docs/**/*.md'], ignore_errors := true) GROUP BY language;
-- per-language averages
WITH analysis AS (
  SELECT language, COUNT(DISTINCT file_path) AS files, COUNT(*) AS total_nodes,
         COUNT(CASE WHEN semantic_type = 'DEFINITION_FUNCTION' THEN 1 END) AS functions,
         COUNT(CASE WHEN semantic_type = 'DEFINITION_CLASS' THEN 1 END) AS classes
  FROM read_ast(['src/**/*.py','lib/**/*.js','api/**/*.ts','core/**/*.cpp'], ignore_errors := true) GROUP BY language)
SELECT language, files, ROUND(functions::FLOAT / files, 2) AS avg_functions_per_file, ROUND(total_nodes::FLOAT / files, 2) AS avg_complexity_per_file
FROM analysis ORDER BY avg_complexity_per_file DESC;
-- basics
LOAD 'sitting_duck';
SELECT COUNT(*) AS total_nodes FROM read_ast('script.py');
SELECT COUNT(*) AS total_nodes FROM read_ast('script.js', 'javascript');
SELECT name, type, file_path FROM read_ast('code.py') WHERE semantic_type = 'DEFINITION_FUNCTION';
SELECT file_path, COUNT(*) AS nodes_per_file FROM read_ast('src/**/*.py', ignore_errors := true) GROUP BY file_path;
SELECT file_path, language, COUNT(*) AS nodes_per_file
FROM read_ast(['src/**/*.py','lib/**/*.js','tests/**/*.ts','include/**/*.hpp'], ignore_errors := true) GROUP BY file_path, language ORDER BY nodes_per_file DESC;
SELECT language, COUNT(*) AS total_functions FROM read_ast(['**/*.py','**/*.js','**/*.cpp'], ignore_errors := true) WHERE semantic_type = 'DEFINITION_FUNCTION' GROUP BY language;
SELECT name, type, language, file_path FROM read_ast('**/*.*', ignore_errors := true) WHERE semantic_type = 'DEFINITION_FUNCTION';
SELECT COUNT(*) AS function_count, language FROM read_ast('src/**/*.*', ignore_errors := true) WHERE semantic_type = 'DEFINITION_FUNCTION' GROUP BY language;
SELECT COUNT(*) AS conditional_count, language FROM read_ast('src/**/*.*', ignore_errors := true) WHERE semantic_type = 'FLOW_CONDITIONAL' GROUP BY language;
SELECT file_path, name, language FROM read_ast('**/*.{py,js,cpp}', ignore_errors := true) WHERE semantic_type = 'COMPUTATION_CALL' AND name IS NOT NULL;
SELECT file_path, type, name, semantic_type, start_line FROM read_ast('**/*.{py,js,cpp}', ignore_errors := true) WHERE semantic_type = 'OPERATOR_ASSIGNMENT' ORDER BY file_path, start_line;
SELECT file_path, name, depth, descendant_count FROM read_ast('**/*.py', ignore_errors := true) WHERE semantic_type = 'DEFINITION_FUNCTION' AND depth > 3 ORDER BY descendant_count DESC;
-- call forms shown in the doc
read_ast('script.py'); read_ast('script.js', 'javascript'); read_ast('src/**/*.py'); read_ast('**/*.{js,ts,py}');
read_ast(['src/**/*.py','lib/**/*.js','tests/**/*.ts']); read_ast(['main.py','utils.js'], 'auto');
read_ast('src/**/*.*', ignore_errors := true); read_ast(['**/*.py','**/*.js'], ignore_errors := true, peek_size := 200);
read_ast(['script.py'], peek_mode := 'lines');   -- INVALID: 'lines' is not a peek mode (error)
SELECT * FROM ast_supported_languages();
SELECT * FROM parse_ast('def hello(): pass', 'python');
-- Scenario 1: inventory
SELECT language, COUNT(*) AS total_nodes, COUNT(CASE WHEN semantic_type = 'DEFINITION_FUNCTION' THEN 1 END) AS functions,
       COUNT(CASE WHEN semantic_type = 'DEFINITION_CLASS' THEN 1 END) AS classes, COUNT(DISTINCT file_path) AS files
FROM read_ast('**/*.*', ignore_errors := true) GROUP BY language ORDER BY total_nodes DESC;
-- Scenario 2: most complex files
SELECT file_path, language, MAX(depth) AS max_depth, COUNT(*) AS total_nodes,
       COUNT(CASE WHEN semantic_type = 'DEFINITION_FUNCTION' THEN 1 END) AS function_count
FROM read_ast('**/*.*', ignore_errors := true) GROUP BY file_path, language HAVING function_count > 5 ORDER BY max_depth DESC, total_nodes DESC;
-- Scenario 3: tests and error handling
SELECT file_path, name, type, language, start_line FROM read_ast('**/*.*', ignore_errors := true)
WHERE semantic_type = 'DEFINITION_FUNCTION' AND (name ILIKE '%test%' OR name ILIKE '%spec%') ORDER BY file_path, start_line;
SELECT file_path, type, language, COUNT(*) AS error_handling_count FROM read_ast('**/*.*', ignore_errors := true)
WHERE semantic_type IN ('ERROR_TRY', 'ERROR_CATCH') GROUP BY file_path, type, language ORDER BY error_handling_count DESC;
-- Scenario 4: tech debt
SELECT file_path, name, type, depth, descendant_count, start_line FROM read_ast('**/*.{py,js,cpp}', ignore_errors := true)
WHERE depth > 6 AND semantic_type IN ('DEFINITION_FUNCTION', 'DEFINITION_CLASS') ORDER BY depth DESC, descendant_count DESC;
SELECT file_path, COUNT(CASE WHEN semantic_type = 'FLOW_CONDITIONAL' THEN 1 END) AS conditionals,
       COUNT(CASE WHEN semantic_type = 'FLOW_LOOP' THEN 1 END) AS loops, COUNT(*) AS total_nodes
FROM read_ast('**/*.py', ignore_errors := true) GROUP BY file_path HAVING (conditionals + loops) > 10 ORDER BY (conditionals + loops) DESC;
-- Scenario 5: function inventory
SELECT file_path, name AS function_name, type, start_line, children_count AS parameter_indicators, descendant_count AS complexity_score,
       SUBSTR(peek, 1, 50) || '...' AS preview
FROM read_ast('src/**/*.py', ignore_errors := true) WHERE semantic_type = 'DEFINITION_FUNCTION' AND name IS NOT NULL ORDER BY file_path, start_line;
-- predicates
WHERE is_literal(semantic_type);  WHERE is_definition(semantic_type);  WHERE is_control_flow(semantic_type);
-- complete workflow
WITH overview AS (SELECT language, COUNT(*) AS files, COUNT(CASE WHEN semantic_type = 'DEFINITION_FUNCTION' THEN 1 END) AS functions
                  FROM read_ast('**/*.*', ignore_errors := true) GROUP BY language),
     complex_functions AS (SELECT file_path, name, depth, descendant_count FROM read_ast('**/*.*', ignore_errors := true)
                           WHERE semantic_type = 'DEFINITION_FUNCTION' AND depth > 5),
     issues AS (SELECT file_path, 'Deep nesting' AS issue_type, COUNT(*) AS count FROM complex_functions GROUP BY file_path)
SELECT o.language, o.files, o.functions, COALESCE(i.count, 0) AS complexity_issues FROM overview o LEFT JOIN issues i ON TRUE ORDER BY complexity_issues DESC;
SELECT file_path, COUNT(*) AS function_count FROM read_ast(['**/*.py','**/*.js'], ignore_errors := true) WHERE semantic_type = 'DEFINITION_FUNCTION' GROUP BY file_path;
```
Doc-vs-source caveats for this page: `peek_mode` valid values are NOT `'auto'|'chars'|'lines'`; keyword tokens
duplicate every definition row unless `NOT is_syntax_only(flags)` is added (the doc's counts of
`DEFINITION_FUNCTION` are ~2x); `'Multi-threading'` listed as planned is already implemented.

### 4.3 CSS selector syntax (`ast_select` / `ast_select_from`)

Steps: `type` (exact tree-sitter type), `#name` (exact `name`), `.class` (semantic alias, see 4.5), `*`.
Compound: `type.class#name[attr=v]:pseudo`. Combinators: `A B` (descendant), `A > B` (child), `A ~ B` (later
sibling), `A + B` (immediately next sibling). **Exactly two steps per combinator chain**; `[attr]`/`:pseudo`
allowed only on the LAST step; longer chains error (#127).

Attributes `[attr op value]`, value quoted or bare; ops: `=`, `*=` (contains), `^=` (starts), `$=` (ends).
Attribute -> column: `name`, `type`, `language`, `semantic` (alias/name), `peek`, `qualified` (qualified_name
string form), `signature` (signature_type), `params` (parameters), `modifier` (`=`/`*=` = "has modifier"),
`annotation`, `receiver`, `file` (file_path, use `[file$="app.py"]`), `line` (start_line). Ops beyond `=` only for
`name, annotation, qualified, signature, receiver, peek, file`; unknown attribute/op -> error. Filters are
NULL-definite: NULL column never matches (and `:not(...)` then matches). `[peek...]` on a table with no peek at all
-> error with re-parse hint.

Pseudo-classes: `:first-child` (sibling_index=0), `:last-child`, `:nth-child(n)` (1-based), `:empty`
(children_count=0), `:root` (depth=0), `:named` (name not null/empty), `:syntax` (is_syntax_only),
`:definition` / `:reference` / `:declaration` (flag name role), `:async :static :abstract :const(|final) :public
:private :protected` (modifiers list), `:decorated` (annotations non-empty), `:typed` (signature_type non-empty),
`:void` (signature NULL/''/void/None), `:variadic` (params text has `*` or `...`), `:calls(name?)`,
`:called-by(name?)`, `:is-called`, `:is-referenced`, `:exported` (flag), `:match(pattern)` / `:contains(pattern)`
(ast_match pattern), `:scope(function|class|module|<type>[#name]|.class)`, `:in-scope(...)` (via `scope.*`),
`:precedes(sel)`, `:follows(sel)`, `:has(sel)`, `:not(sel)`. Unknown pseudo-class -> error.

Pseudo-elements (append to selector, returns the RELATED nodes instead): `::parent`, `::parent-definition`,
`::scope`, `::next-sibling`, `::prev-sibling` / `::previous-sibling`, `::callers`, `::callees`.

```sql
SELECT * FROM ast_select('src/**/*.py', '.function:has(return_statement)');
SELECT * FROM ast_select('src/*.js', 'class_body > method_definition');
SELECT * FROM ast_select('src/*.py', '.function:has(.call#execute):not(:has(try_statement))');
SELECT * FROM ast_select('src/**/*.py', '.func[signature^=int]');
SELECT * FROM ast_select('src/**/*.py', '.call#execute[receiver=con]');
SELECT * FROM ast_select('src/**/*.py', '.call#execute[file$="app.py"][line=42]');
SELECT * FROM ast_select('src/**/*.py', '.fn#process::callers');
CREATE TABLE my_ast AS SELECT * FROM read_ast('src/**/*.py');
SELECT * FROM ast_select_from('my_ast', '.class:named');
SELECT * FROM ast_selector_for('my_ast', 'src/app.py', 42);
```

### 4.4 Pattern matching (`ast_match`)

Pattern = code in the target language with wildcards. `__X__` named capture (uppercase), `__` anonymous;
extended `%__X<*>__%` (0+ siblings), `%__X<+>__%` (1+), `%__<*>__%`, `%__<+>__%`, `%__X<type=T>__%` (type
constraint), `<?>` max 1, `<~>` max 0. Same-named captures must have identical text. `match_syntax := true`
includes punctuation in matching; `match_by := 'semantic_type'` matches cross-language; `depth_fuzz := N` tolerates
depth differences.

```sql
SELECT * FROM ast_match('src/**/*.py', 'my_func(__X__)');
SELECT * FROM ast_match('src/**/*.py', '__F__(__, 2, __X__)');
SELECT * FROM ast_match('src/**/*.js', '__F__(__X__)', language := 'javascript', match_by := 'semantic_type');
SELECT * FROM ast_match('src/**/*.py', 'def __F__(__):
    %__BODY<*>__%
    return __Y__');
SELECT ast_capture(captures, 'X').name, captures['X'][1].peek, captures['BODY'] FROM ast_match('src/**/*.py', 'f(__X__)');
```

### 4.5 `.class` aliases (`is_semantic_type` patterns, case-insensitive in selectors)
FUNCTION/FUNC/FN/METHOD -> DEFINITION_FUNCTION · CALL/INVOKE -> COMPUTATION_CALL · CLASS/CLS/STRUCT/TRAIT/INTERFACE
-> DEFINITION_CLASS · IDENTIFIER/ID/IDENT -> NAME_IDENTIFIER · MODULE/MOD/PACKAGE/NAMESPACE/NS -> DEFINITION_MODULE ·
VARIABLE/VAR/LET/CONST -> DEFINITION_VARIABLE · CONDITIONAL/COND/IF -> FLOW_CONDITIONAL · LOOP/FOR/WHILE ->
FLOW_LOOP · JUMP/RETURN/BREAK/CONTINUE/YIELD -> FLOW_JUMP · DEFINITION/DEF -> kind DEFINITION · LITERAL/LIT/VALUE
-> kind LITERAL · NAME -> kind NAME · FLOW/CONTROL -> kind FLOW_CONTROL · EXTERNAL/EXT -> kind EXTERNAL ·
MEMBER/ATTR/FIELD/PROP -> COMPUTATION_ACCESS · IMPORT/REQUIRE/USE -> EXTERNAL_IMPORT · EXPORT/PUB -> EXTERNAL_EXPORT
· TRY · CATCH/EXCEPT/RESCUE · THROW/RAISE · FINALLY/ENSURE/DEFER · STR/STRING · NUM/NUMBER · BOOL/BOOLEAN ->
LITERAL_ATOMIC · COLL/LIST/DICT/ARRAY/MAP/SET/TUPLE -> LITERAL_STRUCTURED · QUALIFIED/DOTTED · SELF/THIS ->
NAME_SCOPED · LABEL -> NAME_ATTRIBUTE · ARITH/MATH · CMP/COMPARISON · LOGIC/LOGICAL · COMP/COMPREHENSION ->
TRANSFORM_QUERY · COMPUTATION (super kind) · ERROR/ERR (kind) · OPERATOR/OP (kind) · TYPEDEF/TYPE (kind TYPE) ·
PATTERN/PAT · BLOCK (kind ORGANIZATION) · STATEMENT/STMT (kind EXECUTION) · SYNTAX/SYN (kind PARSER_SPECIFIC) ·
TRANSFORM/XFORM · COMMENT -> METADATA_COMMENT only · METADATA/META (kind) · ACCESS -> kind COMPUTATION_NODE ·
anything else -> exact full name (`'DEFINITION_FUNCTION'`).

### 4.6 Structural search (`docs/how-to/structural-search.md` idioms)
```sql
SELECT * FROM ast_has('src/**/*.py', 'function_definition', 'return_statement');           -- functions with a return
SELECT * FROM ast_not_has('src/**/*.py', 'function_definition', 'return_statement');       -- functions without one
SELECT * FROM ast_inside('src/**/*.py', 'call', 'function_definition', 'main');            -- calls inside main()
SELECT * FROM ast_has('src/**/*.py', 'function_definition', 'call', descendant_name := 'eval');
SELECT * FROM ast_precedes('src/**/*.py', 'call', 'return_statement');                     -- calls before a return
SELECT * FROM ast_follows('src/**/*.py', 'call', 'try_statement');
```

---------------------------------------------------------------------------------------------------------------

## 5. Architecture notes that affect query writing

- **Flat table per node, DFS pre-order.** `node_id` restarts at 0 for every file. Subtree of `a` =
  `d.node_id > a.node_id AND d.node_id <= a.node_id + a.descendant_count AND d.file_path = a.file_path`.
  `descendant_count` excludes the node; `children_count` = direct children; `depth` root=0. Always join on
  `file_path` too when multiple files are in the table.
- **Children/parent reconstruction:** `parent_id`; siblings ordered by `sibling_index` (0-based) or `node_id`.
  First child of a call node (`sibling_index = 0`) is the call target (used by `ast_get_calls` to classify method
  calls by target type `attribute|member_expression|field_expression|selector_expression|navigation_expression|field_access`).
- **scope STRUCT** precomputed at parse time: `scope.function` / `scope.class` / `scope.module` / `scope.current`
  are node_ids of the nearest enclosing IS_SCOPE node of that kind (NULL/0 at module level); `scope.stack` is
  populated only on scope nodes (join `s.node_id = a.scope.current` to get a node's chain). Hash joins on
  `scope.function` replace range joins (ast_callees went 20 s -> <1 s on DuckDB's tree).
- **Names:** qualified targets reduce to the last identifier (`obj.method()` -> name `method`, receiver `obj`;
  `pkg.Class` -> `Class`). `qualified_name` is a LIST of segments; string form via `ast_qualified_name_as_string`.
  Keywords inherit the construct's semantic_type with IS_SYNTAX_ONLY.
- **Streaming + threads:** `read_ast` is a streaming table function emitting 2048-row chunks; each thread claims
  files with an atomic `next_file_idx.fetch_add`; `MaxThreads()` = 1 when < 4 files, else = number of files. File
  list is sorted+deduped at init but **output order across files is NOT guaranteed with >= 4 files** — add
  `ORDER BY file_path, node_id` when order matters. Within one file rows are in node_id order.
- **Bind-time constants:** `read_ast`, `parse_ast`, `read_text`-based macros need literal/constant arguments (paths,
  language, selector, pattern). They cannot take column values; `LATERAL` over `read_ast(col)` does not work.
  Column-valued parsing: `parse_ast_list(col, lang)` (scalar). Column-valued selectors: not supported
  (`ast_select_rules` WIP).
- **Parse once, query many:** `CREATE TABLE ast AS SELECT * FROM read_ast('src/**/*.py', peek := 'full',
  source := 'full');` then use `ast_select_from('ast', ...)`, `ast_children('ast', id)` etc. Macros taking a path
  re-parse on every call (each `ast_definitions('src/**')` call re-reads all files).
- **Memory:** per-file parse results are freed after streaming; `peek := 'full'` multiplies memory by tree depth.
  Caps: 50 MiB/file, 30 s/file, 10M nodes/file (tunable, `<= 0` disables).
- **Macro internals rely on:** `is_construct(flags)` (= not syntax-only), `is_name_definition(flags)`,
  `semantic_type = 'COMPUTATION_CALL'` (ast_callees/ast_callers/ast_imports use string equality — refined codes
  such as constructor calls may be missed **[unverified]**), `is_function_call` (mask-safe) in ast_get_calls /
  ast_security_audit / ast_dead_code.

---------------------------------------------------------------------------------------------------------------

## 6. Gotchas

1. **Path vs table name.** `ast_definitions('my_table')` is wrong — it globs for a file named `my_table` (error
   `read_ast needs at least one file to read`). Docs (`analysis-macros.md`, README) sometimes show table names for
   whole-file macros; the source takes paths. Table-name macros are listed in 1.3.
2. **Explicit `language` filters by extension**, it does not override detection. Use `parse_ast_list` over
   `read_text` for extensionless files.
3. `.h` -> C, not C++ (so C++ headers named `.h` get the C grammar: templates/classes become ERROR nodes).
4. `peek_size := N` has no effect unless mode is `custom` (`peek := N` or `peek_mode := 'custom'`); smart peek caps
   at 80 chars (docs say "~64"/120). `peek_mode := 'lines'|'auto'|'chars'` -> error.
5. `ast_select` returns `peek` = NULL unless the selector contains `[peek`; use `ast_select_from` over a table
   parsed with `peek := 'full'` when you need text. `ast_replace`/`ast_patch` need `source := 'full'`.
6. `semantic_type = 'X'` vs refinements (see 2.2). Also `IN ('ERROR_TRY','ERROR_CATCH')` casts the same way.
7. Keyword duplicates: filter `NOT is_syntax_only(flags)` (or `is_construct(flags)`) and `name != ''` for
   definitions; otherwise `def`, `class`, `function` tokens count as definitions.
8. `ignore_errors := true` hides missing files, unknown extensions, unsupported languages, read/parse failures and
   oversize/timeout errors; syntax errors never raise anyway (ERROR nodes). Without it, one bad file aborts the query.
9. Multi-thread ordering (>= 4 files): add `ORDER BY`.
10. `ast_select_rules` / `ast_select_list` crash at bind time (DuckDB planner bug); `is_type_definition`,
    `is_boolean_literal` always false; `read_ast_streaming` not registered; `ast_functions/ast_classes/ast_imports`
    BLOB helpers not registered (`ast_imports` IS a macro with different meaning).
11. `ast_match` default `language := 'python'` — pass `language :=` for anything else (also parses the pattern).
12. CSS combinators: max two steps; `[attr]`/`:pseudo` only on last step; unknown attribute/pseudo -> error;
    NULL-definite filters (`[signature=int]` on untyped code matches nothing; `:not([signature=int])` matches all).
13. Bind-time literal requirement: `read_ast(col)`, `parse_ast(col, ...)`, `ast_get_source(col, ...)` in LATERAL
    fail; `read_text` in `ast_source_of`/`ast_patch` needs the same literal glob you parsed with.
14. Version pinning: build for **DuckDB 1.5.5**; community-extension binaries are per DuckDB version; a Python
    `duckdb` wheel must match (`pip install duckdb==1.5.5`). `INSTALL sitting_duck FROM community` needs network
    access to `community-extensions.duckdb.org` (blocked by a proxy in this sandbox: HTTP 403). WASM builds exist
    but cannot `register_language` (no dlopen); Windows support is via the community pipeline (no known limits
    documented beyond the generic ones).
15. `git://path@rev` URIs (duck_tails extension) pass straight through to the VFS; detection strips the scheme and
    `@rev` (`detect_language('git://./src/main.py@HEAD')` -> `python`). Globs are NOT expanded inside URIs.
    duck_hunt (log/diff parsing) and duck_tails are sibling extensions in the same suite; sitting_duck explicitly
    excludes logs/diffs from scope.
16. Runtime grammars need `SET sitting_duck_enable_runtime_grammars = true` before `register_language(...)`.
17. `sibling_index` is INTEGER (docs: UINTEGER) and only with `structure := 'full'`; `start_line` etc. are
    UINTEGER — casting arithmetic (`max_depth::INTEGER - func_depth::INTEGER`) avoids unsigned underflow.
18. `ast_supported_languages()` columns are `language, extensions, parser_type, node_type_count` (docs list other
    names). `ast_function_metrics` / `ast_functions_containing` columns differ from the docs' tables (use 1.3).
19. `receiver` column and `ast_resolve_entity` macro exist but are undocumented in the reference pages.
20. `get_super_kind`/`get_kind` return VARCHAR names (docs imply codes). `is_call` also true for
    `EXECUTION_STATEMENT_CALL`; `is_identifier` also true for NAME_QUALIFIED/NAME_SCOPED.
21. `CLAUDE.md` of the extension still says `read_ast` options are only `ignore_errors, peek_size, peek_mode`
    and describes `ast_get_*`/`ast_to_*`/`ast_find_*`/`ast_extract_*` categories that are NOT registered.
22. `DEFINITION_MODULE` is for named module/namespace definitions; file roots are `ORGANIZATION_CONTAINER`.
23. Type aliases/typedefs/interfaces/enums map to `DEFINITION_CLASS` (no DEFINITION_TYPE).

---------------------------------------------------------------------------------------------------------------

## 7. Recipes

Common prelude (parse once, both repos):
```sql
LOAD sitting_duck;
-- C++ DuckDB extension repo (headers named .hpp -> cpp; .h -> c)
CREATE OR REPLACE TABLE ast AS
SELECT * FROM read_ast(['src/**/*.cpp', 'src/**/*.hpp', 'src/include/**/*.hpp', 'test/**/*.cpp'],
                       ignore_errors := true, peek := 'full', source := 'full')
ORDER BY file_path, node_id;
-- Python/TypeScript monorepo (exclude generated + deps by NOT globbing them)
CREATE OR REPLACE TABLE ast AS
SELECT * FROM read_ast(['platform/backend/**/*.py', 'platform/frontend/src/**/*.ts', 'platform/frontend/src/**/*.tsx'],
                       ignore_errors := true, peek := 'full')
WHERE file_path NOT LIKE '%/node_modules/%' AND file_path NOT LIKE '%/src/client/%' AND file_path NOT LIKE '%/.venv/%'
ORDER BY file_path, node_id;
-- refinement-safe definition rows, reused below
CREATE OR REPLACE VIEW defs AS
SELECT * FROM ast WHERE is_definition(semantic_type) AND NOT is_syntax_only(flags) AND name IS NOT NULL AND name != '';
```

### 7.1 Functions per file (with signatures)
```sql
SELECT file_path, name, ast_qualified_name_as_string(qualified_name) AS qname, signature_type,
       list_transform(parameters, lambda p: p.name || ':' || COALESCE(p.type,'')) AS params, modifiers,
       start_line, end_line, end_line - start_line + 1 AS lines, descendant_count
FROM defs WHERE is_function_definition(semantic_type)
ORDER BY file_path, start_line;
-- C++: methods only (inside a class/struct) vs free functions
SELECT file_path, name, scope.class IS NOT NULL AS is_method FROM defs WHERE is_function_definition(semantic_type) AND language = 'cpp';
-- C++ declarations vs definitions (header prototypes are NAME_DECLARATION)
SELECT file_path, name, name_role(flags) AS role FROM ast WHERE is_function_definition(semantic_type) AND binds_name(flags) AND NOT is_syntax_only(flags);
-- TS/JS: include arrow functions assigned to consts (refined LAMBDA still passes is_function_definition)
SELECT file_path, name, type FROM defs WHERE is_function_definition(semantic_type) AND language IN ('typescript','javascript');
```

### 7.2 Files with most functions / classes
```sql
SELECT file_path, language,
       COUNT(*) FILTER (WHERE is_function_definition(semantic_type)) AS functions,
       COUNT(*) FILTER (WHERE is_class_definition(semantic_type)) AS classes
FROM defs GROUP BY file_path, language ORDER BY functions DESC LIMIT 25;
-- or the macro (re-parses): SELECT * FROM ast_function_metrics('src/**/*.cpp') ORDER BY cyclomatic DESC;
```

### 7.3 Call graph
```sql
-- per call site with enclosing function (scope.function hash join)
SELECT c.file_path, COALESCE(f.name, '<module>') AS caller, c.name AS callee, c.receiver, c.start_line
FROM ast c LEFT JOIN ast f ON f.node_id = c.scope.function AND f.file_path = c.file_path
WHERE is_function_call(c.semantic_type) AND NOT is_syntax_only(c.flags) AND c.name IS NOT NULL AND c.name != '';
-- aggregated edges (macro form, re-parses): SELECT * FROM ast_call_graph('platform/backend/**/*.py') ORDER BY call_count DESC;
-- callers of X, name-based (cross-file; no type resolution)
SELECT c.file_path, COALESCE(f.name,'<module>') AS caller, c.start_line, c.peek
FROM ast c LEFT JOIN ast f ON f.node_id = c.scope.function AND f.file_path = c.file_path
WHERE is_function_call(c.semantic_type) AND c.name = 'RegisterFunction';
-- callers of X, scope-resolved within a file (handles shadowing): SELECT * FROM ast_find_references('src/**/*.py', 'process') WHERE ref_kind = 'call';
-- CSS: SELECT * FROM ast_select_from('ast', '.fn#RegisterFunction::callers');
-- callees of a function
SELECT DISTINCT c.name FROM ast c JOIN ast f ON f.node_id = c.scope.function AND f.file_path = c.file_path
WHERE is_function_call(c.semantic_type) AND f.name = 'LoadInternal';
```

### 7.4 TODO / FIXME
```sql
SELECT file_path, start_line, trim(peek) AS comment
FROM ast WHERE is_semantic_type(semantic_type, 'COMMENT') AND regexp_matches(peek, '\b(TODO|FIXME|XXX|HACK)\b')
ORDER BY file_path, start_line;
-- with owner: regexp_extract(peek, '(TODO|FIXME)\(([^)]*)\)', 2)
```

### 7.5 Imports / dependency graph
```sql
-- normalized (file -> module -> imported name); Python from-imports, TS/JS specifiers, C/C++ #include (name = header path)
SELECT * FROM ast_imports(['platform/backend/**/*.py', 'platform/frontend/src/**/*.ts']);
-- raw, from the table: import statements per file
SELECT file_path, name AS module, type, start_line FROM ast
WHERE is_import(semantic_type) AND NOT is_syntax_only(flags) AND descendant_count > 0 AND name != ''
  AND parent_id NOT IN (SELECT node_id FROM ast p WHERE is_import(p.semantic_type) AND p.file_path = ast.file_path);
-- C++ include graph (edges file -> header)
SELECT file_path AS src, name AS header FROM ast WHERE language IN ('cpp','c') AND type = 'preproc_include' AND name != '';
-- internal dependency edges in a Python package (module path from file path)
WITH e AS (SELECT file_path, source_module FROM ast_imports('platform/backend/**/*.py'))
SELECT file_path, source_module FROM e WHERE source_module LIKE 'app.%' OR source_module LIKE '.%';
-- fan-in: most imported modules
SELECT source_module, COUNT(DISTINCT file_path) AS importers FROM ast_imports('platform/**/*.{py,ts,tsx}') GROUP BY 1 ORDER BY 2 DESC;
-- exported symbols (public API) per file
SELECT file_path, name, type FROM ast_exports('platform/frontend/src/**/*.ts');
```

### 7.6 Other useful ones
```sql
-- classes and their direct members
SELECT c.file_path, c.name AS class, m.name AS member, m.type FROM defs c, LATERAL (SELECT * FROM ast_class_members('ast', c.node_id)) m
WHERE is_class_definition(c.semantic_type);   -- note: table macro with column arg; if the planner rejects the LATERAL, loop per class
-- decorated FastAPI routes
SELECT file_path, name, annotations FROM defs WHERE is_function_definition(semantic_type) AND annotations LIKE '%router.%';
-- nodes covering a line / source text
SELECT type, name, start_line, end_line FROM ast_containing_line('src/foo.cpp', 120) LIMIT 5;
SELECT ast_get_source_numbered('src/foo.cpp', 100, 130);
SELECT * FROM ast_source_of('src/**/*.cpp', 'LoadInternal', kind := 'function');
-- unused functions/classes (heuristic): SELECT * FROM ast_dead_code(['src/**/*.py']);
-- security scan: SELECT * FROM ast_security_audit('platform/backend/**/*.py') WHERE risk_level = 'high';
-- rename a symbol (pure): SELECT * FROM ast_replace('src/main.py', 'identifier[name=old_fn]', 'new_fn');
```

---------------------------------------------------------------------------------------------------------------

## 8. Docs vs source discrepancies (summary list)

1. Whole-file macros take paths/globs, not table names (docs/README mix them up); table-name macros are the tree
   navigation helpers, `ast_select_from`, `ast_to_blocks_from`, `ast_selector_for`, `ast_patch`.
2. `ast_match` takes a path and defaults `language := 'python'`.
3. Explicit `language` acts as an extension filter: `read_ast('script', 'python')`, `read_ast('Makefile','bash')`
   examples in docs fail.
4. `.h` maps to `c`, not `cpp`.
5. `ast_supported_languages` columns: `language, extensions, parser_type, node_type_count`.
6. `sibling_index` is INTEGER and only at `structure := 'full'`.
7. `receiver` column (native context) and `ast_resolve_entity` macro are undocumented.
8. `get_super_kind` / `get_kind` return VARCHAR.
9. `is_boolean_literal`, `is_type_definition` always false.
10. Flag table in `semantic-types.md` is stale (real bits in 2.3).
11. `EXECUTION_INVOCATION` (docs) is `EXECUTION_STATEMENT_CALL`; `COMPUTATION_LAMBDA` (docs) is `COMPUTATION_CLOSURE`.
12. YAML/Scala/F#/Haskell/Julia mentioned in docs are not built; `duckdb` has no file extension mapping.
13. Method-call `name` IS populated (method name) and `receiver` gives the object; README text about NULL names for
    method calls is stale.
14. `ast_function_metrics`, `ast_functions_containing` output columns differ from the docs' tables.
15. `ast_select` leaves `peek` NULL unless `[peek` is in the selector.
16. `ast_select_rules`/`ast_select_list` crash (documented as WIP only in the SQL file).
17. Multi-threaded `read_ast` (>= 4 files) does not preserve file order; docs claim "results sorted by file path".
18. Smart peek is capped at 80 chars (docs: "~64" / "peek_size default 120"); `peek_size` alone is a no-op in smart mode.
19. `peek_mode` valid values are `none|smart|full|custom|<N>` (docs: `auto|chars|lines`).
20. `parse_ast` has no `ignore_errors/prune/max_depth/peek_size/peek_mode/batch_size` named params.
21. Extension `CLAUDE.md` describes unregistered `ast_get_*`/`ast_to_*`/`ast_find_*`/`ast_extract_*` families and
    an outdated option list.
22. `is_call` includes `EXECUTION_STATEMENT_CALL`; `is_identifier` includes NAME_QUALIFIED/NAME_SCOPED (docs say
    identifiers only).

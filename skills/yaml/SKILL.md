---
name: yaml
description: >
  Read, inspect, validate, extract, convert, or write YAML with DuckDB's yaml extension.
  Reach for this when the source is .yaml/.yml, YAML frontmatter, an inline YAML value,
  or a remote description.yml that should become typed relational columns.
---

# YAML

Read `/duckstack:duck` first. On this machine the extension is already loaded on the selected
dev server; do not `LOAD`, `INSTALL`, or change YAML settings through dev. Run one read-only
statement inside `quack_query`:

```bash
QUACK_TOKEN="$(cat ~/.duck/token)" duckdb :memory: -c "
LOAD quack;
FROM quack_query('quack:localhost:9494', \$\$<one SELECT>\$\$,
                 token := getenv('QUACK_TOKEN'));"
```

Use the YAML reader or `::YAML` type before extracting fields. Do not use `regexp_*`, string
surgery, or `LIKE` against YAML text.

## Verified function surface

Verified against dev through `quack_query` on 2026-09-19 with:

```sql
SELECT function_name, function_type, parameters, parameter_types, varargs
FROM duckdb_functions()
WHERE function_name IN (<the names below>)
ORDER BY function_name, function_type, parameter_types::VARCHAR;
```

Names such as `col0` and `col1` below are not placeholders: they are the real positional
parameter names reported by `duckdb_functions()`. Named table-function options are reported
exactly as installed. Defaults are not present in that metadata, so do not invent them; pass an
option explicitly when its value matters.

### Table functions

| Function | Kind | Parameters reported by `duckdb_functions()` |
|---|---|---|
| `parse_yaml` | table | `col0 VARCHAR`, `list_column_name VARCHAR`, `frontmatter_as_columns BOOLEAN`, `expand_root_sequence BOOLEAN`, `multi_document ANY` |
| `read_yaml` | table | `col0 ANY`, `multi_document ANY`, `records VARCHAR`, `columns ANY`, `list_column_name VARCHAR`, `expand_root_sequence BOOLEAN`, `frontmatter_as_columns BOOLEAN`, `sample_size BIGINT`, `ignore_errors BOOLEAN`, `maximum_file_size BIGINT`, `strip_document_suffixes BOOLEAN`, `maximum_sample_files BIGINT`, `maximum_object_size BIGINT`, `auto_detect BOOLEAN` |
| `read_yaml_frontmatter` | table | `col0 ANY`, `filename BOOLEAN`, `content BOOLEAN`, `as_yaml_objects BOOLEAN` |
| `read_yaml_objects` | table | `col0 ANY`, `strip_document_suffixes BOOLEAN`, `columns ANY`, `sample_size BIGINT`, `ignore_errors BOOLEAN`, `maximum_file_size BIGINT`, `maximum_sample_files BIGINT`, `maximum_object_size BIGINT`, `multi_document ANY`, `auto_detect BOOLEAN` |
| `yaml_array_elements` | table | `col0 YAML` |
| `yaml_each` | table | `col0 YAML` |

### Scalar functions

| Function | Kind | Positional parameters and overloads |
|---|---|---|
| `copy_format_yaml` | scalar | `col0 ANY`, variadic `ANY` |
| `format_yaml` | scalar | `col0 ANY`, variadic `ANY` |
| `from_yaml` | scalar | `col0 VARCHAR|YAML`, `col1 ANY` |
| `to_yaml` | scalar | `col0 ANY` |
| `value_to_yaml` | scalar | `col0 ANY` |
| `yaml` | scalar | `col0 VARCHAR` |
| `yaml_array_length` | scalar | `col0 YAML`[, `col1 VARCHAR`] |
| `yaml_build_object` | scalar | variadic `ANY` (no fixed parameters) |
| `yaml_contains` | scalar | `col0 VARCHAR|YAML`, `col1 VARCHAR|YAML` |
| `yaml_exists` | scalar | `col0 VARCHAR|YAML`, `col1 VARCHAR` |
| `yaml_extract` | scalar | `col0 VARCHAR|YAML`, `col1 VARCHAR` |
| `yaml_extract_path` | scalar | `col0 VARCHAR|YAML`, `col1 VARCHAR` |
| `yaml_extract_path_text` | scalar | `col0 VARCHAR|YAML`, `col1 VARCHAR` |
| `yaml_extract_string` | scalar | `col0 VARCHAR|YAML`, `col1 VARCHAR` |
| `yaml_get_default_style` | scalar | none |
| `yaml_get_max_expansion_nodes` | scalar | none |
| `yaml_get_max_input_size` | scalar | none |
| `yaml_get_max_nesting_depth` | scalar | none |
| `yaml_keys` | scalar | `col0 YAML`[, `col1 VARCHAR`] |
| `yaml_merge_patch` | scalar | `col0 VARCHAR|YAML`, `col1 VARCHAR|YAML` |
| `yaml_set_default_style` | scalar | `col0 VARCHAR` |
| `yaml_set_max_expansion_nodes` | scalar | `col0 BIGINT` |
| `yaml_set_max_input_size` | scalar | `col0 BIGINT` |
| `yaml_set_max_nesting_depth` | scalar | `col0 BIGINT` |
| `yaml_structure` | scalar | `col0 VARCHAR|YAML` |
| `yaml_to_json` | scalar | `col0 YAML` |
| `yaml_type` | scalar | `col0 VARCHAR|YAML`[, `col1 VARCHAR`] |
| `yaml_valid` | scalar | `col0 VARCHAR|YAML` |
| `yaml_value` | scalar | `col0 VARCHAR|YAML`, `col1 VARCHAR` |

`yaml_agg(col0 ANY)` is an aggregate, not a scalar or table function. The `yaml_set_*`
functions mutate connection settings; list them for completeness but do not call them on the
shared dev server.

## Worked example — remote `description.yml`

This exact statement was run through `quack_query`:

```sql
-- read_yaml(col0; named options: multi_document, records, columns, list_column_name,
-- expand_root_sequence, frontmatter_as_columns, sample_size, ignore_errors,
-- maximum_file_size, strip_document_suffixes, maximum_sample_files,
-- maximum_object_size, auto_detect; defaults are not exposed by duckdb_functions()).
SELECT extension.name, extension.description, extension.version,
       extension.language, extension.build, extension.license,
       repo.github, repo.ref
FROM read_yaml(
  'https://raw.githubusercontent.com/duckdb/community-extensions/main/extensions/yaml/description.yml'
);
```

Real output:

```text
name  description                                                                                                      version  language  build  license  github                         ref
yaml  Read YAML files into DuckDB with native YAML type support, comprehensive extraction functions, and seamless JSON interoperability  1.9.1    C++       cmake  MIT      teaguesterling/duckdb_yaml  40f5f94afc70d68d7b7db44c0ea74601afe42fa9
```

The starting claim is correct: `read_yaml('<url>')` reads this URL directly and infers nested
`extension` and `repo` structs.

## Gotchas verified while writing this skill

- `read_yaml` is literal-bound. This correlated call failed:

  ```sql
  WITH urls(url) AS (VALUES ('https://example.invalid/config.yml'))
  SELECT * FROM urls CROSS JOIN LATERAL read_yaml(url);
  ```

  Exact error: `Table function "read_yaml" does not support lateral join column parameters ...
  The function only supports literals as parameters.` Use `/duckstack:self-dispatch` when URLs
  are rows; do not delete the intended fan-out.
- `duckdb_functions()` exposes more current parameters than the extension prose docs. In this
  build, for example, `read_yaml_objects` does not report a `filename` option, while it does
  report `maximum_file_size` and `strip_document_suffixes`. Trust the live catalog.
- Schema inference is source-dependent. Keep the raw relation, run `DESCRIBE` at `LIMIT 1`, and
  only then select nested fields by name.


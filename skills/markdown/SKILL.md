---
name: markdown
description: >
  Read, analyze, convert, or emit Markdown with DuckDB's markdown extension. Reach for this
  when .md files, Markdown text, headings, sections, code blocks, links, tables, frontmatter,
  or conversion to typed document blocks are the data source.
---

# Markdown

Read `/duckstack:duck` first. The selected dev server already has `markdown` and `webbed`
loaded. Do not `LOAD` or `INSTALL` through dev. Run one read-only statement inside
`quack_query`; keep Markdown as `MARKDOWN`/`md` and rendered markup as `HTML`, not strings to
search with `LIKE` or `regexp_*`.

## Verified function surface

Verified against dev through `quack_query` on 2026-09-19 by selecting `function_name`,
`function_type`, `parameters`, `parameter_types`, and `varargs` from `duckdb_functions()`.
`col0`, `col1`, and so on are the real positional names reported by the engine.

### Table functions

| Function | Kind | Parameters reported by `duckdb_functions()` |
|---|---|---|
| `read_markdown` | table | `col0 VARCHAR`; named: `include_stats`, `flavor`, `maximum_file_size`, `extract_metadata`, `extract_extensions`, `normalize_content`, `include_filepath`, `filename`, `content_as_varchar` |
| `read_markdown` | table | `col0 VARCHAR[]`; the same named options, reported in reverse registration order |
| `read_markdown_blocks` | table | `col0 VARCHAR`; named: `extract_metadata`, `maximum_file_size`, `extract_extensions`, `normalize_content`, `include_filepath`, `filename` |
| `read_markdown_blocks` | table | `col0 VARCHAR[]`; the same named options, reported in reverse registration order |
| `read_markdown_sections` | table | `col0 VARCHAR`; named: `include_stats`, `flavor`, `maximum_file_size`, `extract_metadata`, `extract_extensions`, `normalize_content`, `min_level`, `max_level`, `max_content_length`, `include_empty_sections`, `include_content`, `include_filepath`, `filename`, `content_as_varchar`, `content_mode`, `max_depth` |
| `read_markdown_sections` | table | `col0 VARCHAR[]`; the same named options, reported in reverse registration order |

Defaults are not exposed by `duckdb_functions()`; pass any option whose value matters.

### Scalar functions

| Function | Kind | Positional parameters and overloads |
|---|---|---|
| `duck_block_to_md` | scalar | `col0 STRUCT(kind, element_type, content, level, encoding, attributes, element_order)` |
| `duck_blocks_to_md` | scalar | `col0 STRUCT(...)[]` |
| `duck_blocks_to_sections` | scalar | `col0 STRUCT(...)[]` |
| `md_extract_code_blocks` | scalar | `col0 md` |
| `md_extract_frontmatter` | scalar | `col0 md` |
| `md_extract_images` | scalar | `col0 md` |
| `md_extract_links` | scalar | `col0 md` |
| `md_extract_metadata` | scalar | `col0 md` |
| `md_extract_section` | scalar | `col0 md`, `col1 VARCHAR`[, `col2 BOOLEAN`] |
| `md_extract_sections` | scalar | `col0 md`; or `col0 VARCHAR`, `col1 INTEGER`, `col2 INTEGER`[, `col3 VARCHAR`] |
| `md_extract_table_rows` | scalar | `col0 md` |
| `md_extract_tables_json` | scalar | `col0 md` |
| `md_extract_tags` | scalar | `col0 md` |
| `md_extract_wikilinks` | scalar | `col0 md` |
| `md_section_breadcrumb` | scalar | `col0 VARCHAR`, `col1 VARCHAR` |
| `md_stats` | scalar | `col0 md`[, `col1 BOOLEAN`] |
| `md_to_html` | scalar | `col0 md` |
| `md_to_text` | scalar | `col0 md` |
| `md_valid` | scalar | `col0 VARCHAR` |
| `parse_markdown_to_duck_blocks` | scalar | `col0 VARCHAR` |
| `value_to_md` | scalar | `col0 ANY` |

For the cross-extension bridge used below, live metadata reports
`html_to_duck_blocks(col0 HTML|VARCHAR)` as a `webbed` scalar returning
`STRUCT(kind, element_type, content, level, encoding, attributes, element_order)[]`.

## Worked example — README to typed blocks

This exact statement was run through `quack_query`:

```sql
WITH raw AS (
  -- read_text(files): no named parameters.
  SELECT *
  FROM read_text('https://raw.githubusercontent.com/duckdb/duckdb/main/README.md')
), blocks AS (
  SELECT ordinality, block.*
  FROM raw
  -- md_to_html(col0 md): no optional parameters.
  -- html_to_duck_blocks(col0 HTML|VARCHAR): no optional parameters.
  CROSS JOIN UNNEST(html_to_duck_blocks(md_to_html(content)::HTML))
       WITH ORDINALITY AS t(block, ordinality)
)
SELECT ordinality, element_type, content, level, encoding, attributes
FROM blocks
ORDER BY ordinality
LIMIT 8;
```

Real output, abbreviated only by the query's own `LIMIT 8`:

```text
1  heading    DuckDB                                                                 level=1  encoding=text  {heading_level=2}
2  paragraph  NULL                                                                   level=1  encoding=text  {}
3  text       DuckDB is a high-performance analytical database system. It is ...     level=2  encoding=text  {}
4  link       several extensions designed to make SQL easier to use                  level=2  encoding=text  {href=https://duckdb.org/docs/current/sql/dialect/friendly_sql.html}
5  text       .                                                                       level=2  encoding=text  {}
6  paragraph  NULL                                                                   level=1  encoding=text  {}
7  text       DuckDB is available as a                                                level=2  encoding=text  {}
8  link       standalone CLI application                                             level=2  encoding=text  {href=https://duckdb.org/docs/current/clients/cli/overview}
```

The starting claim is correct. `md_to_html(text)` followed by
`html_to_duck_blocks(...::HTML)` yields typed document blocks.

## Gotchas verified while writing this skill

- `md_to_html(...)` returns `VARCHAR`, not `HTML`. A live type probe returned
  `rendered_type=VARCHAR`, `cast_type=HTML`, and a list of `duck_block` structs after
  `html_to_duck_blocks`. The latter has a VARCHAR overload, but the explicit `::HTML` cast is
  the required structural boundary on this machine.
- Block rows are hierarchical. Container rows such as `paragraph` can have `content = NULL`;
  their child `text` and `link` rows hold the content. Do not discard the container or infer
  hierarchy from text position.
- `level` is tree depth, not necessarily the Markdown heading number. In the real output the
  heading row had `level=1` and `attributes['heading_level']='2'`.
- Reader table functions take literal paths. A correlated `read_markdown(path)` probe failed
  with `Table function "read_markdown" does not support lateral join column parameters ...
  The function only supports literals as parameters.` If paths are rows, use
  `/duckstack:self-dispatch` rather than deleting the intended fan-out.

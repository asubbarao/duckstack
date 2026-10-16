-- shell_readers.sql: SQL owns the calls; Tera emits only Bash/reader grammar.
-- Render with autoescape := false and template_path := '<this-directory>/*.tera'.
-- Every args/flags/parameters value is a trusted authored fragment, not an escaping API.
-- Do not retry with a different reader: a command may have performed a write before parsing failed.
-- A streaming LIMIT can close the pipe early; it is a preview, not proof that side effects completed.
-- These are parser smoke cases. For one short fixed call, use the reader directly rather than Tera.
-- Shell stages acquire/convert what SQL cannot; transform the returned rows in later SQL CTEs.
-- Plain ShellFS pipelines report the last stage's status. Use an explicit Bash pipefail runner when needed.

-- Installed DuckDB 1.5.5 signatures, 2026-09-29:
-- Refresh these lists on the selected service with:
--   SELECT function_name, parameters, parameter_types
--   FROM duckdb_functions()
--   WHERE function_name IN ('read_csv', 'read_json')
--   ORDER BY function_name;
-- read_csv(path VARCHAR|VARCHAR[]; named options:
--   files_to_sniff, thousands, strict_mode, dtypes, null_padding, parallel,
--   decimal_separator, buffer_size, rejects_scan, maximum_line_size, quote,
--   max_line_size, names, ignore_errors, compression, column_types, rejects_table,
--   normalize_names, store_rejects, all_varchar, auto_detect, timestampformat,
--   sample_size, auto_type_candidates, force_not_null, rejects_limit, columns, sep,
--   hive_partitioning, comment, allow_quoted_nulls, escape, new_line, union_by_name,
--   column_names, dateformat, delim, header, filename, hive_types, encoding, nullstr,
--   types, skip, hive_types_autocast).
-- Defaults worth remembering: auto_detect=true, parallel=true, strict_mode=true,
-- sample_size=20480, files_to_sniff=10, encoding='utf-8', union_by_name=false.
-- read_csv already sniffs format and types; `_auto` is unnecessary.
--
-- read_json(path VARCHAR|VARCHAR[]; named options:
--   records, map_inference_threshold, timestampformat, date_format,
--   field_appearance_threshold, dateformat, sample_size, columns, format,
--   convert_strings_to_integers, ignore_errors, maximum_object_size, auto_detect,
--   maximum_depth, union_by_name, maximum_sample_files, compression,
--   timestamp_format, hive_types, hive_partitioning, hive_types_autocast, filename).
-- read_json already detects array/newline/unstructured shape and types; set format only when known.
-- Supplying columns is a projection: unspecified JSON fields disappear.
--
-- Encoding: core read_csv supports UTF-8, UTF-16 and Latin-1. `INSTALL encodings; LOAD
-- encodings;` adds 1,000+ CSV encodings through the same `encoding :=` option. ICU supplies
-- collations/time zones; it is not a generic arbitrary-byte decoder. For unknown/bad text,
-- preserve bytes with read_blob. Convert deliberately (for example an iconv pipeline), then
-- choose one reader. read_lines is streaming and keeps line_number/content/byte_offset/file_path;
-- read_text reads whole objects in a batch and is not the streaming fallback. Quote read_lines'
-- reserved option name exactly as `"trim" := true`; bare `trim := true` can bind but return no rows.
-- Result contracts in the samples below:
--   read_json -> inferred columns `id BIGINT, ok BOOLEAN`.
--   read_csv  -> header-derived columns `code VARCHAR, active VARCHAR`; all_varchar preserves `001`.
--   read_lines -> `line_number, content, byte_offset, file_path`; `"trim"` removes line endings.

-- Current inline command/params form. Native-file and pipeline cases: ../../self-dispatch/references/inline.sql.
WITH source AS (
    SELECT 'find' AS command, ['/private/tmp', '-maxdepth', '0', '-type', 'd'] AS args,
           {'header': false, 'all_varchar': true} AS params
), c AS (
    SELECT * REPLACE (list_transform(args, arg -> quote_literal(arg)) AS args) FROM source
), rendered AS (
    SELECT tera_render($t$
SELECT * FROM read_csv($cmd${{ command }} {{ args | join(sep=" ") }} |$cmd$
{% for name, value in params %}, {{ name }} := {{ value }}{% endfor %})
$t$, c::JSON, autoescape := false) AS sql FROM c
), posted AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts
    FROM rendered
)
SELECT r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

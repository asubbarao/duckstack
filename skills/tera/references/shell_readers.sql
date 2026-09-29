-- shell_readers.sql: SQL owns the calls; Tera emits only Bash/reader grammar.
-- Render with autoescape := false and template_path := '<this-directory>/*.tera'.
-- Every args/flags/parameters value is a trusted authored fragment, not an escaping API.
-- Do not retry with a different reader: a command may have performed a write before parsing failed.
-- A streaming LIMIT can close the pipe early; it is a preview, not proof that side effects completed.

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

WITH calls AS (
  SELECT 'json' AS label, json_object(
    'reader', {'name': 'read_json', 'parameters': [
      {'name': 'format', 'value': $v$'newline_delimited'$v$},
      {'name': 'maximum_depth', 'value': '-1'}]},
    'stages', [{'command': 'printf', 'args': [$a$'%s\n'$a$, $a$'{"id":1,"ok":true}'$a$], 'flags': []}],
    'sql_tag', 'json_pipe', 'row_limit', 100) AS context
  UNION ALL
  SELECT 'csv', json_object(
    'reader', {'name': 'read_csv', 'parameters': [
      {'name': 'header', 'value': 'true'},
      {'name': 'all_varchar', 'value': 'true'}]},
    'stages', [{'command': 'printf', 'args': [$a$'code,active\n001,true\n'$a$], 'flags': []}],
    'sql_tag', 'csv_pipe', 'row_limit', 100)
  UNION ALL
  SELECT 'lines', json_object(
    'reader', {'name': 'read_lines', 'parameters': [{'name': '"trim"', 'value': 'true'}]},
    'stages', [
      {'command': 'printf', 'args': [$a$'alpha\nbeta\n'$a$], 'flags': []},
      {'command': 'sed', 'args': [], 'flags': [{'name': '-n', 'value': $a$'1,2p'$a$}]}
    ],
    'sql_tag', 'lines_pipe', 'row_limit', 100)
), rendered AS (
  SELECT label, tera_render(
    'shell_reader.tera', context, autoescape := false,
    template_path := '/Users/aloksubbarao/duckdb-skills/skills/tera/references/*.tera'
  ) AS statement
  FROM calls
)
SELECT label, is_parsable(statement) AS parsable, len(statement) AS statement_chars, statement
FROM rendered
ORDER BY label;

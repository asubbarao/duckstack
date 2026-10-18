-- shell_readers.sql: which reader for host-command output, and what its options are on this build.
-- The dispatch itself is the shell template: ../../self-dispatch/templates/canonical.sql example 1 (shell.tera,
-- reader + command + options as text). Use the reader directly when the command is one fixed literal.
--
-- read_csv and read_json already sniff shape and types: no `_auto`, no `columns := {...}` (a JSON `columns`
-- is a projection: unspecified fields disappear), set `format` only when known.
-- read_lines streams and keeps line_number, content, byte_offset, file_path. Quote its option as
-- `"trim" := true`; bare `trim := true` can bind and return no rows. read_text and read_blob read whole
-- objects in a batch; read_blob keeps bytes when text decoding fails.
-- Encoding: core read_csv supports UTF-8, UTF-16 and Latin-1; `INSTALL encodings FROM community; LOAD encodings;`
-- adds 1,000+ through the same `encoding :=` option. ICU is collations and time zones, not a byte decoder.
-- Never retry a command with a different reader after a parse failure: it may already have written.
-- A streaming LIMIT can close the pipe early: a preview is not proof every side effect completed.
-- Plain ShellFS pipelines report the last stage's status; run `bash -o pipefail -c` when an upstream failure matters.
--
-- The installed readers and every option they take (verified on dev 2026-10-17):
SELECT function_name, parameters, parameter_types
FROM duckdb_functions()
WHERE function_name IN ('read_csv', 'read_json', 'read_lines', 'read_text', 'read_blob')
ORDER BY function_name;

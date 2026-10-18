-- Every code line in duckdb-skills (skills/ and server/) that breaks a house rule: one row per file:line:rule.
-- Run on dev (MCP query). Rules are rows: add one when the owner names a new antipattern; nothing else changes.
-- Code lines are .sql/.tera lines that are not comments, and .md lines inside ``` fences. duckstack-review is skipped
-- because its BAD examples are deliberate.
WITH tracked_files AS (
    SELECT list(quote_literal('/Users/aloksubbarao/duckdb-skills/' || content)) AS paths
    FROM read_lines('git -C /Users/aloksubbarao/duckdb-skills ls-files -co --exclude-standard -- skills server |', "trim" := true)
    WHERE string_split(content, '.')[-1] IN ('sql', 'md', 'tera')
      AND NOT starts_with(content, 'skills/duckstack-review/')
      AND NOT starts_with(content, 'skills/self-dispatch/templates/')
), read_statement AS (
    SELECT tera_render($tera$
        SELECT filename AS path, content FROM read_text([{{ paths | join(sep=", ") }}])
    $tera$, tracked_files::JSON, autoescape := false) AS sql
    FROM tracked_files
), self_dispatch AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM read_statement
), file_contents AS (
    SELECT file ->> 'path' AS path, file ->> 'content' AS content
    FROM self_dispatch CROSS JOIN UNNEST(receipts) AS each_receipt(receipt)
    CROSS JOIN UNNEST(receipt.body::JSON[]) AS each_file(file)
), file_lines AS (
    SELECT path, line_number, line, string_split(path, '.')[-1] AS extension,
           sum(CASE WHEN starts_with(trim(line), '```') THEN 1 ELSE 0 END) OVER (PARTITION BY path ORDER BY line_number) AS fences_so_far
    FROM file_contents CROSS JOIN UNNEST(string_split(content, $n$
$n$)) WITH ORDINALITY AS each_line(line, line_number)
), code_lines AS (
    SELECT path, line_number, line FROM file_lines
    WHERE NOT starts_with(trim(line), '--') AND NOT starts_with(trim(line), '```')
      AND (extension = 'md') IS NOT DISTINCT FROM (fences_so_far % 2 = 1)
), rules AS (
    SELECT 'printf(' AS needle, 'text built with printf; render with tera' AS rule UNION ALL
    SELECT 'columns := {', 'reader schema declared; SELECT * and let the reader bring its columns' UNION ALL
    SELECT 'maximum_depth', 'JSON digging; read the keys as columns upstream' UNION ALL
    SELECT 'from_json(', 'structure string passed to a JSON parser' UNION ALL
    SELECT 'array_to_string(', 'banned; tera join' UNION ALL
    SELECT 'count(*)', 'star count' UNION ALL
    SELECT 'limit 1;', 'limit-one' UNION ALL
    SELECT '; do ', 'bash loop; one statement per row' UNION ALL
    SELECT 'bash_loop_fallback_method', 'FALLBACK used: rows usually replace it; justify or rewrite' UNION ALL
    SELECT 'jq -c ''{', 'jq reshaping; jq only splits an array into lines (jq_array_to_lines.tera)' UNION ALL
    SELECT '| sed ', 'sed doing SQL''s job' UNION ALL
    SELECT '| awk ', 'awk doing SQL''s job' UNION ALL
    SELECT '| jq ', 'jq doing SQL''s job' UNION ALL
    SELECT ') filter (where', 'aggregate FILTER' UNION ALL
    SELECT 'with recursive', 'recursive CTE' UNION ALL
    SELECT 'create or replace table', 'table created; propose it first' UNION ALL
    SELECT 'create table', 'table created; propose it first' UNION ALL
    SELECT 'create macro', 'macro created; propose it first' UNION ALL
    SELECT 'create or replace macro', 'macro created; propose it first' UNION ALL
    SELECT 'chr(39)', 'quote building from character codes' UNION ALL
    SELECT 'chr(34)', 'quote building from character codes' UNION ALL
    SELECT 'left join lateral', 'left-joined lateral' UNION ALL
    SELECT '{% for', 'logic inside a tera template' UNION ALL
    SELECT '{% if', 'logic inside a tera template'
)
SELECT replace(code_lines.path, '/Users/aloksubbarao/duckdb-skills/', '') AS file, code_lines.line_number, rules.rule,
       left(trim(code_lines.line), 110) AS line
FROM code_lines JOIN rules ON contains(lower(code_lines.line), rules.needle)
ORDER BY file, code_lines.line_number;

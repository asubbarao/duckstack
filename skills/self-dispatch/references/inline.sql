-- Inline Tera: SQL supplies rows; render complete SQL; aggregate native self-posts; UNNEST receipts.
-- Run each block on the selected dev MCP (127.0.0.1:9495). selfdispatch and quote_literal are loaded macros; no new server, tables or template files.
-- autoescape=false: these are SQL/shell programs, not HTML. c::JSON serializes the context.
-- params keys are SQL option names; values render as SQL expressions. Booleans/numbers need no quoting.
-- For a text option use a SQL literal, e.g. {'delim': $$','$$}; HTML escaping is not SQL quoting.
-- Args below are raw values; quote_literal wraps each shell token in single quotes.
-- Reader names and SQL option names are authored code. Fixed dollar-quote delimiters must be absent from their input.
-- Plain pipelines report the last stage's exit status. These examples exercise successful read-only commands.
-- Preserve failure receipts; never retry an uncertain write. Arrays do not guarantee concurrency or execution order.

-- 1. SQL without ShellFS. Expected answers: 42, 43.
WITH c AS (
    SELECT n FROM range(42, 44) AS t(n)
), rendered AS (
    SELECT tera_render('SELECT {{ n }} AS answer', c::JSON, autoescape := false) AS sql FROM c
), posted AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts
    FROM rendered
)
SELECT r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

-- 2. Native file reader, with := params. ScalarFS supplies a CSV fixture without writing a file.
WITH c AS (
    SELECT 'read_csv' AS reader,
           to_scalarfs_uri('code,active' || chr(10) || '001,true') AS source,
           {'header': true, 'all_varchar': true} AS params
), rendered AS (
    SELECT tera_render($t$
SELECT * FROM {{ reader }}($src${{ source }}$src$
{% for name, value in params %}, {{ name }} := {{ value }}{% endfor %})
$t$, c::JSON, autoescape := false) AS sql FROM c
), posted AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts
    FROM rendered
)
SELECT r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

-- 3. Bash-command dispatch: command, argument array and := params are data.
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

-- 4. Repeated pipelines: arrays contain arguments; the template owns pipes and repetition.
-- Expected ids: 1, 2, 3. No Bash for-loop, JSON literal payload or pipe in the argument data.
WITH source AS (
    SELECT [
        [['seq', '2'], ['jq', '-Rc', '{id: tonumber}']],
        [['seq', '3', '3'], ['jq', '-Rc', '{id: tonumber}']]
    ] AS commands
), c AS (
    SELECT list_transform(commands, pipeline -> list_transform(pipeline, args -> list_transform(args, arg ->
        quote_literal(arg)
    ))) AS commands FROM source
), rendered AS (
    SELECT tera_render($t$
SELECT * FROM read_json($cmd$
{% for pipeline in commands %}
{% for args in pipeline %}{{ args | join(sep=" ") }}{% if not loop.last %} | {% endif %}{% endfor %}
{% endfor %}
|$cmd$, format := 'newline_delimited')
$t$, c::JSON, autoescape := false) AS sql FROM c
), posted AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts
    FROM rendered
)
SELECT r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

-- 5. Reading results back: each statement writes its rows; the next stage reads the files.
-- Never parse the receipt body (no from_json structure string, no json_each). Expected answers: 42, 43.
-- The output directory must already exist; a missing one is a 500 "Cannot open file" receipt.
WITH c AS (
    SELECT n FROM range(42, 44) AS t(n)
), rendered AS (
    SELECT tera_render($t$
COPY (SELECT {{ n }} AS answer) TO '/private/tmp/selfdispatch_answer_{{ n }}.parquet' (FORMAT parquet)
$t$, c::JSON, autoescape := false) AS sql FROM c
), posted AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts
    FROM rendered
)
SELECT r.status FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

SELECT answer FROM read_parquet('/private/tmp/selfdispatch_answer_*.parquet') ORDER BY answer;

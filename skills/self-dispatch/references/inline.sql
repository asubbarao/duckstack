-- Inline Tera: the first CTE declares every value; an inline template only fills holes; array_agg(selfdispatch(sql));
-- CROSS JOIN UNNEST the receipts. For shell, pipeline, sql, network and loop shapes use the named templates
-- (../templates/canonical.sql); this file is the inline form for statements those do not cover.
-- Run each block on dev (MCP http://localhost:9495/mcp/). selfdispatch and quote_literal are the only macros.
-- autoescape := false: these are SQL programs, not HTML. Options are declared as SQL text (', header := true').
-- Keep failure receipts; never retry an uncertain write. An array of posts has no execution order.
-- Verified on dev 2026-10-17.

-- 1. Plain SQL. Expected bodies: [{"answer":42}], [{"answer":43}].
WITH answers AS (
    SELECT n FROM range(42, 44) AS r(n)
), rendered AS (
    SELECT tera_render('SELECT {{ n }} AS answer', a::JSON, autoescape := false) AS sql FROM answers AS a
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

-- 2. A native file reader, options as text. ScalarFS supplies the CSV without writing a file.
-- Expected body: [{"code":"001","active":"true"}] (all_varchar keeps the leading zero).
WITH fixture AS (
    SELECT 'read_csv' AS reader,
           quote_literal(to_scalarfs_uri($csv$code,active
001,true$csv$)) AS source,
           ', header := true, all_varchar := true' AS options
), rendered AS (
    SELECT tera_render('SELECT * FROM {{ reader }}({{ source }}{{ options }})', f::JSON, autoescape := false) AS sql
    FROM fixture AS f
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

-- 3. Each statement writes its own rows to a file; the next stage reads the files, not the receipt bodies.
-- The output directory must already exist; a missing one is a 500 "Cannot open file" receipt.
WITH answers AS (
    SELECT n FROM range(42, 44) AS r(n)
), rendered AS (
    SELECT tera_render($t$COPY (SELECT {{ n }} AS answer) TO '/private/tmp/selfdispatch_answer_{{ n }}.parquet' (FORMAT parquet)$t$,
                       a::JSON, autoescape := false) AS sql
    FROM answers AS a
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

SELECT answer FROM read_parquet('/private/tmp/selfdispatch_answer_*.parquet') ORDER BY answer;

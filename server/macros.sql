-- Macros Alok approved, read by setup.sql and ~/.duckdbrc.
-- quote_literal: a value as a single-quoted SQL literal, for SQL that SQL writes. A ' inside is doubled and NULL
-- stays NULL, as in Postgres: it's -> 'it''s'.
CREATE OR REPLACE MACRO quote_literal(s) AS CASE WHEN s IS NOT NULL THEN concat($q$'$q$, replace(s::VARCHAR, $q$'$q$, $q$''$q$), $q$'$q$) END;
-- selfdispatch: post one SQL statement to dev's /sql and return the receipt (status, body, error). Callers collect
-- receipts with array_agg(selfdispatch(sql)) and UNNEST them; a failed statement stays a receipt, no rows post nothing.
-- The post always goes to dev itself; whatever varies by row (a URL, a command, a file) goes inside the statement.
-- A failed statement comes back as a non-200 with the DuckDB error in the body's detail; error carries it, so
-- failures show in receipt.error. The one-element list makes the lambda post once (a macro argument used twice posts twice).
CREATE OR REPLACE MACRO selfdispatch(sql) AS
    list_transform([quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', sql)::VARCHAR)],
        p -> {'status': p.status, 'body': p.body,
              'error': coalesce(p.error, CASE WHEN p.status IS DISTINCT FROM 200
                                              THEN coalesce(try_cast(p.body AS JSON) ->> 'detail', p.body::VARCHAR) END)})[1];

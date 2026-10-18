-- Macros Alok approved, read by setup.sql and ~/.duckdbrc.
-- quote_literal: a value as a single-quoted SQL literal, for SQL that SQL writes.
CREATE OR REPLACE MACRO quote_literal(s) AS CONCAT(chr(39), s, chr(39));
-- selfdispatch: post one SQL statement to dev's /sql and return the receipt (status, body, error). Callers collect
-- receipts with array_agg(selfdispatch(sql)) and UNNEST them; a failed statement stays a receipt, no rows post nothing.
-- The post always goes to dev itself; whatever varies by row (a URL, a command, a file) goes inside the statement.
CREATE OR REPLACE MACRO selfdispatch(sql) AS
    quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', sql)::VARCHAR);

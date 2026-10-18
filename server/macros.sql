-- Macros Alok approved, read by setup.sql and ~/.duckdbrc.
-- quote_literal: a value as a single-quoted SQL literal, for SQL that SQL writes.
CREATE OR REPLACE MACRO quote_literal(s) AS CONCAT(chr(39), s, chr(39));
-- selfdispatch: post one SQL statement to dev's /sql and return the receipt (status, body, error). Callers collect
-- receipts with array_agg(selfdispatch(sql)) and UNNEST them; a failed statement stays a receipt, no rows post nothing.
CREATE OR REPLACE MACRO selfdispatch(sql, url := 'http://127.0.0.1:9495/sql') AS
    quackapi_post(url, json_object('sql', sql)::VARCHAR);

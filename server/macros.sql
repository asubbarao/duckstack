-- Macros Alok approved, read by setup.sql and ~/.duckdbrc.
-- quote_literal: a value as a single-quoted SQL literal, for SQL that SQL writes.
CREATE OR REPLACE MACRO quote_literal(s) AS CONCAT(chr(39), s, chr(39));
-- selfdispatch: post one SQL statement to dev's /sql and return the receipt (status, body, error). Callers collect
-- receipts with array_agg(selfdispatch(sql)) and UNNEST them; a failed statement stays a receipt, no rows post nothing.
CREATE OR REPLACE MACRO selfdispatch(sql, protocol := 'http', hostname := '127.0.0.1', port := '9495', pathname := '/sql',
                                     content_type := 'application/json', headers := MAP {}::MAP(VARCHAR, VARCHAR)) AS
    quackapi_post(url_build(protocol := protocol, hostname := hostname, port := port, pathname := pathname),
                  json_object('sql', sql)::VARCHAR, content_type, headers);

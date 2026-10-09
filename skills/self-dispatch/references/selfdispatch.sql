-- Two direct transports to the existing dev service. No additional server.
WITH statements AS (
    SELECT n AS source_key, 'SELECT ' || n || ' AS answer' AS q
    FROM generate_series(1, 4) AS numbers(n)
), requests AS (
    SELECT *, MAP {'sql': q} AS form, json_object('sql', q) AS body
    FROM statements
), posted AS (
    SELECT *,
           http_post_form('http://127.0.0.1:9495/sql', MAP {}, form) AS form_receipt,
           http_post('http://127.0.0.1:9495/sql',
                     MAP {'Content-Type': 'application/json'}, body) AS json_receipt
    FROM requests
), packed AS (
    SELECT array_agg(posted) AS receipts FROM posted
)
SELECT item.*
FROM packed CROSS JOIN UNNEST(receipts) AS r(item);

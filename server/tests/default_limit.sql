-- Exercise the public server doors, not a copy of the limit classifier.
WITH cases(name, statement, expected_rows) AS (VALUES
    ('implicit', $$SELECT i AS n, true AS ok FROM range(50) r(i)$$, 3),
    ('explicit', $$SELECT i AS n, true AS ok FROM range(50) r(i) LIMIT 35$$, 35),
    ('all', $$SELECT i AS n, true AS ok FROM range(50) r(i) LIMIT ALL$$, 50),
    ('inner', $$SELECT * FROM (SELECT i AS n, true AS ok FROM range(50) r(i) LIMIT 40)$$, 3),
    ('comment', $$SELECT i AS n, true AS ok FROM range(50) r(i) -- LIMIT 3$$, 3)
), doors(path) AS (VALUES ('/sql'), ('/query')),
receipts AS (
    SELECT *, http_post('http://127.0.0.1:9495' || path,
        MAP{'Content-Type':'application/json'}, json_object('sql', statement)) AS response
    FROM cases CROSS JOIN doors
)
SELECT *, json_array_length((response->>'body')::JSON) AS actual_rows,
       CASE WHEN response->>'status' = '200' AND actual_rows = expected_rows
            THEN 'PASS' ELSE error(name || ' at ' || path || ': ' || response::VARCHAR) END AS result
FROM receipts LIMIT ALL;

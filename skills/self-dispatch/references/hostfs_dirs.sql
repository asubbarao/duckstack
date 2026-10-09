WITH program AS (
    SELECT tera_render(
        'hostfs_dirs.tera',
        json_object('root_sql', 'getenv(''HOME'')', 'levels', [1,2,3,4],
                    'self_uri', 'http://127.0.0.1:9495/sql'),
        autoescape := false,
        template_path := getenv('HOME') || '/duckdb-skills/skills/self-dispatch/references/tera/*.tera'
    ) AS statement
), dispatched AS (
    SELECT statement,
           http_post('http://127.0.0.1:9495/sql',
                     MAP {'Content-Type': 'application/json'},
                     json_object('sql', statement)) AS receipt
    FROM program
), result AS (
    SELECT *, try_cast(receipt ->> '$.status' AS INTEGER) AS dispatch_status,
           json_extract(try_cast(receipt ->> '$.body' AS JSON), '$[*]') AS rows,
           CASE WHEN len(rows) > 0 THEN rows ELSE [NULL] END AS result_rows
    FROM dispatched
)
SELECT folder_row ->> '$.path' AS path,
       folder_row -> '$.files' AS files,
       folder_row -> '$.folders' AS folders,
       folder_row AS metadata,
       CASE WHEN position = 1 THEN statement END AS rendered_sql,
       CASE WHEN position = 1 THEN receipt END AS dispatch_receipt,
       dispatch_status
FROM result
CROSS JOIN UNNEST(result_rows) WITH ORDINALITY AS r(folder_row, position);

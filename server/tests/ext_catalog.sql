-- Run as one SQL body on dev. Real loopback 404s exercise cache promotion without external fixtures.
CREATE TEMP TABLE catalog_before AS
SELECT url, fetched_at, sha256(response::VARCHAR) AS digest FROM agents.ext_page;
CREATE TEMP TABLE catalog_rerun AS
SELECT http_post('http://127.0.0.1:9495/sql', MAP{'Content-Type':'application/json'},
                 json_object('sql', content)) AS receipt
FROM read_text('/Users/aloksubbarao/duckdb-skills/server/ext_catalog.sql');
SELECT CASE WHEN receipt.status = 200 THEN 'rerun succeeded'
            ELSE error(receipt::VARCHAR) END AS result FROM catalog_rerun;
WITH difference AS (
    FROM catalog_before
    EXCEPT ALL
    SELECT url, fetched_at, sha256(response::VARCHAR) FROM agents.ext_page
), reverse_difference AS (
    SELECT url, fetched_at, sha256(response::VARCHAR) FROM agents.ext_page
    EXCEPT ALL FROM catalog_before
)
SELECT CASE WHEN NOT EXISTS (FROM difference) AND NOT EXISTS (FROM reverse_difference)
            THEN 'fresh cache unchanged' ELSE error('fresh cache changed') END AS result;

SELECT error('test schema already exists; refusing to overwrite it')
FROM duckdb_schemas() WHERE schema_name = 'catalog_http_regression';
CREATE SCHEMA catalog_http_regression;
CREATE TEMP TABLE catalog_failure AS
SELECT http_post('http://127.0.0.1:9495/sql', MAP{'Content-Type':'application/json'},
    json_object('sql', replace(replace(content, 'agents.', 'catalog_http_regression.'),
        'https://duckdb.org/community_extensions/list_of_extensions',
        'http://127.0.0.1:9495/__catalog_regression_missing'))) AS receipt
FROM read_text('/Users/aloksubbarao/duckdb-skills/server/ext_catalog.sql');
SELECT CASE WHEN receipt.status = 200 THEN 'failed fetch handled'
            ELSE error(receipt::VARCHAR) END AS result FROM catalog_failure;
SELECT CASE WHEN count(url) = 0 THEN 'error page not cached'
            ELSE error('HTTP error entered successful cache') END AS result
FROM catalog_http_regression.ext_page;
SELECT CASE WHEN len(list(url)) = 1 AND bool_and(response->>'status' = '404')
            THEN 'raw 404 retained' ELSE error('failure receipt lost') END AS result
FROM catalog_http_regression.ext_fetch_errors;
DROP SCHEMA catalog_http_regression CASCADE;

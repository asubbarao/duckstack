-- Run with CATALOG_SOURCE_ROOT=<checkout> duckdb :memory: -f this_file.sql.
-- Compile the production DDL/MERGE bodies into one isolated fixture program.
-- Only the fetch input SELECTs are replaced; publication logic executes unchanged.
LOAD shellfs;
SET VARIABLE catalog_test_program_path = '/tmp/catalog-merge-' || uuid()::VARCHAR || '.sql';
COPY (
WITH source AS (
    SELECT content FROM read_text(getenv('CATALOG_SOURCE_ROOT') || '/server/ext_catalog.sql')
    UNION ALL
    SELECT content FROM read_text(getenv('CATALOG_SOURCE_ROOT') || '/readthedocs_catalog.sql')
), ddl AS (
    SELECT 'CREATE TABLE IF NOT EXISTS ' || split_part(part, ';', 1) || ';' AS statement
    FROM source CROSS JOIN UNNEST(string_split(content, 'CREATE TABLE IF NOT EXISTS ')[2:]) t(part)
), merges AS (
    SELECT 'MERGE INTO ' || split_part(part, ';', 1) || ';' AS statement,
           split_part(statement, ' ', 3) AS target
    FROM source CROSS JOIN UNNEST(string_split(content, 'MERGE INTO ')[2:]) t(part)
), fixture_merges AS (
    SELECT target, CASE
        WHEN target IN ('lake.agents.ext_fetch', 'lake.agents.ext_doc_fetch') THEN
            left(statement, strpos(statement, 'USING (') + len('USING (') - 1)
            || CASE WHEN target = 'lake.agents.ext_fetch'
                THEN ' SELECT url, fetched_at, response FROM fixture_ext '
                ELSE ' SELECT * FROM fixture_ext_doc ' END
            || substring(statement, strpos(statement, ') AS incoming ON'))
        ELSE statement END AS statement
    FROM merges
), sections AS (
    SELECT 'ddl' AS section, statement, '' AS target FROM ddl
    UNION ALL
    SELECT CASE WHEN target = 'lake.agents.ext_doc_source' THEN 'seed' ELSE 'publish' END,
        statement, target FROM fixture_merges
    UNION ALL
    SELECT 'views', 'CREATE VIEW agents.' || split_part(target, '.', 3)
        || ' AS FROM ' || target || ';', target FROM merges
), bodies AS (
    SELECT string_agg(statement, chr(10) ORDER BY target) FILTER (WHERE section = 'seed') AS seed,
        string_agg(statement, chr(10) ORDER BY target) FILTER (WHERE section = 'publish') AS publish,
        string_agg(statement, chr(10) ORDER BY target) FILTER (WHERE section = 'ddl') AS ddl,
        string_agg(statement, chr(10) ORDER BY target) FILTER (WHERE section = 'views') AS views
    FROM sections
)
SELECT $sql$
INSTALL ducklake; LOAD ducklake;
ATTACH 'ducklake::memory:' AS lake (DATA_PATH ('/tmp/catalog-merge-data-' || uuid()::VARCHAR), DATA_INLINING_ROW_LIMIT 0);
CREATE SCHEMA lake.agents; CREATE SCHEMA agents;
$sql$ || bodies.ddl || bodies.views || $sql$
CREATE TEMP TABLE fixture_ext AS
SELECT 'fixture://page' AS url, TIMESTAMPTZ '2026-10-01' AS fetched_at,
       json_object('status', 200, 'body', 'initial') AS response;
CREATE TEMP TABLE fixture_ext_doc AS
SELECT url, 'html' AS representation, fetched_at, response FROM fixture_ext
UNION ALL SELECT url, 'markdown', fetched_at, json_object('status', 200, 'body', 'markdown') FROM fixture_ext;
$sql$ || bodies.seed || $sql$
CREATE TEMP TABLE before_seed AS FROM lake.snapshots();
$sql$ || bodies.seed || $sql$
SELECT CASE WHEN EXISTS (FROM lake.snapshots() EXCEPT ALL FROM before_seed)
    THEN error('repeated seed changed snapshots') ELSE 'seed unchanged' END;
$sql$ || bodies.publish || $sql$
CREATE TEMP TABLE before_repeat AS FROM lake.snapshots();
$sql$ || bodies.publish || $sql$
SELECT CASE WHEN EXISTS (FROM lake.snapshots() EXCEPT ALL FROM before_repeat)
    THEN error('repeated publication changed snapshots') ELSE 'publication unchanged' END;
WITH keys AS (
    SELECT 'source' AS kind, extension_name AS key, doc_url AS representation FROM lake.agents.ext_doc_source
    UNION ALL SELECT 'fetch', url, '' FROM lake.agents.ext_fetch
    UNION ALL SELECT 'page', url, '' FROM lake.agents.ext_page
    UNION ALL SELECT 'doc_fetch', url, representation FROM lake.agents.ext_doc_fetch
    UNION ALL SELECT 'doc_page', url, representation FROM lake.agents.ext_doc_page
), duplicates AS (SELECT * FROM keys GROUP BY ALL HAVING sum(1) > 1)
SELECT CASE WHEN EXISTS (FROM duplicates) THEN error('duplicate upsert keys') ELSE 'keys unique' END;
SELECT CASE WHEN len(list(url)) = 2
    THEN 'representations independent' ELSE error('representation lost') END FROM lake.agents.ext_doc_page;
UPDATE fixture_ext SET fetched_at = TIMESTAMPTZ '2026-10-02', response = json_object('status', 200, 'body', 'changed');
UPDATE fixture_ext_doc SET fetched_at = TIMESTAMPTZ '2026-10-02', response = json_object('status', 200, 'body', 'changed') WHERE representation = 'html';
$sql$ || bodies.publish || $sql$
WITH changed AS (
    SELECT response->>'body' AS body FROM lake.agents.ext_page
    UNION ALL SELECT response->>'body' FROM lake.agents.ext_doc_page WHERE representation = 'html'
)
SELECT CASE WHEN bool_and(body = 'changed') AND len(list(body)) = 2
    THEN 'changed responses updated' ELSE error('changed response lost') END FROM changed;
CREATE TEMP TABLE before_failed_page AS FROM lake.agents.ext_page;
CREATE TEMP TABLE before_failed_doc AS FROM lake.agents.ext_doc_page;
UPDATE fixture_ext SET fetched_at = TIMESTAMPTZ '2026-10-03', response = json_object('status', 500, 'body', 'failure');
UPDATE fixture_ext_doc SET fetched_at = TIMESTAMPTZ '2026-10-03', response = json_object('status', 500, 'body', 'failure') WHERE representation = 'html';
$sql$ || bodies.publish || $sql$
WITH difference AS (
    (FROM before_failed_page EXCEPT ALL FROM lake.agents.ext_page)
    UNION ALL (FROM lake.agents.ext_page EXCEPT ALL FROM before_failed_page)
), doc_difference AS (
    (FROM before_failed_doc EXCEPT ALL FROM lake.agents.ext_doc_page)
    UNION ALL (FROM lake.agents.ext_doc_page EXCEPT ALL FROM before_failed_doc)
)
SELECT CASE WHEN EXISTS (FROM difference) THEN error('failed fetch replaced page')
    WHEN EXISTS (FROM doc_difference) THEN error('failed fetch replaced doc page')
    ELSE 'successful pages preserved' END;
WITH failures AS (
    SELECT response->>'status' AS status FROM lake.agents.ext_fetch
    UNION ALL SELECT response->>'status' FROM lake.agents.ext_doc_fetch WHERE representation = 'html'
)
SELECT CASE WHEN bool_and(status = '500') AND len(list(status)) = 2
    THEN 'raw failures retained' ELSE error('failure receipt lost') END FROM failures;
$sql$ AS program
FROM bodies
) TO (getvariable('catalog_test_program_path')) (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
SELECT content AS fixture_results FROM read_text(
    'duckdb :memory: -csv -noheader -f ' || getvariable('catalog_test_program_path') || ' 2>&1 |');

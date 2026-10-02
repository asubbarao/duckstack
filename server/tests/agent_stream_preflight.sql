-- Preflight regression: each malformed or unexpectedly small source is rejected before MERGE.
CREATE OR REPLACE TEMP TABLE stream_preflight_cases AS
SELECT 'healthy' AS scenario, 100::BIGINT AS source_rows, 100::BIGINT AS delta_rows,
       100::BIGINT AS nonnull_ids, 100::BIGINT AS distinct_ids, 100::BIGINT AS previous_source_rows, 200 AS expected_status
UNION ALL SELECT 'empty', 0, 0, 0, 0, 100, 422
UNION ALL SELECT 'null_id', 100, 2, 1, 1, 100, 422
UNION ALL SELECT 'duplicate_id', 100, 2, 2, 1, 100, 422
UNION ALL SELECT 'large_loss', 94, 94, 94, 94, 100, 422;
CREATE SCHEMA IF NOT EXISTS agent_stream_preflight_test;
CREATE OR REPLACE TABLE agent_stream_preflight_test.target AS
SELECT scenario, 'original' AS payload FROM stream_preflight_cases;
CREATE OR REPLACE TEMP TABLE stream_preflight_programs AS
SELECT scenario, expected_status,
    printf($sql$SELECT CASE WHEN %d = 0 THEN error('stream source is empty')
                             WHEN %d IS DISTINCT FROM %d THEN error('stream source has NULL ids')
                             WHEN %d IS DISTINCT FROM %d THEN error('stream source has duplicate ids')
                             WHEN %d < %d * 0.95 THEN error('stream source fell below 95 percent of the last successful snapshot')
                             ELSE 'stream preflight passed' END AS preflight$sql$,
        source_rows, delta_rows, nonnull_ids, delta_rows, distinct_ids, source_rows, previous_source_rows) ||
        printf($sql$; UPDATE agent_stream_preflight_test.target SET payload = 'mutated' WHERE scenario = '%s'$sql$, scenario) AS statement
FROM stream_preflight_cases;
CREATE OR REPLACE TEMP TABLE stream_preflight_receipts AS
SELECT scenario, expected_status,
       http_post_form('http://localhost:9495/sql', MAP{}, MAP{'sql': statement}) AS receipt
FROM stream_preflight_programs;
CREATE OR REPLACE TEMP TABLE stream_preflight_checks AS
SELECT receipt.status = expected_status AS passed
FROM stream_preflight_receipts
UNION ALL
SELECT target.payload = CASE WHEN cases.expected_status = 200 THEN 'mutated' ELSE 'original' END
FROM agent_stream_preflight_test.target AS target
JOIN stream_preflight_cases AS cases USING (scenario);
DROP SCHEMA agent_stream_preflight_test CASCADE;
SELECT CASE WHEN bool_and(passed)
            THEN 'pass: healthy input mutates while empty/null/duplicate/large-loss sources fail closed before target changes'
            ELSE error('stream preflight regression') END AS verification
FROM stream_preflight_checks;

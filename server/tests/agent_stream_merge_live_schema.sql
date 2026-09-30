-- Bind MERGE against the production stream schema without persistent writes.
CREATE OR REPLACE TEMP TABLE stream_merge_live_target AS SELECT * FROM agent.stream LIMIT 0;
CREATE OR REPLACE TEMP TABLE stream_merge_live_source AS SELECT * FROM agent.stream LIMIT 20;
INSERT INTO stream_merge_live_target BY NAME SELECT * FROM stream_merge_live_source;
CREATE OR REPLACE TEMP TABLE stream_merge_live_ranked AS
SELECT id, row_number() OVER (ORDER BY id) AS row_rank FROM stream_merge_live_source;
DELETE FROM stream_merge_live_source
WHERE id IN (SELECT id FROM stream_merge_live_ranked WHERE row_rank = 1);
UPDATE stream_merge_live_source
SET message_content = coalesce(message_content, '') || ' merge-schema-test'
WHERE id IN (SELECT id FROM stream_merge_live_ranked WHERE row_rank = 2);
MERGE INTO stream_merge_live_target AS dst
USING stream_merge_live_source AS src
ON dst.id = src.id
WHEN MATCHED AND dst IS DISTINCT FROM src THEN UPDATE BY NAME
WHEN NOT MATCHED THEN INSERT BY NAME
WHEN NOT MATCHED BY SOURCE THEN DELETE;
WITH summary AS (
    SELECT count(1) = 19 AS passed FROM stream_merge_live_target
    UNION ALL SELECT count(1) = 1 FROM stream_merge_live_target
        WHERE message_content LIKE '% merge-schema-test'
)
SELECT CASE WHEN bool_and(passed)
            THEN 'pass: MERGE binds live schema including source column without persistent writes'
            ELSE error('live-schema merge regression') END AS verification
FROM summary;

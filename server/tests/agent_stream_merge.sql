-- Native MERGE regression includes a source-named column and a real second no-op merge.
CREATE OR REPLACE TEMP TABLE stream_merge_target (
    id VARCHAR PRIMARY KEY, source VARCHAR, content VARCHAR, nullable VARCHAR
);
INSERT INTO stream_merge_target VALUES
    ('keep', 'reader', 'same', NULL), ('update', 'reader', 'old', NULL), ('delete', 'reader', 'gone', 'x'),
    ('null-to-value', 'reader', NULL, NULL), ('value-to-null', 'reader', 'clear', NULL);
CREATE OR REPLACE TEMP TABLE stream_merge_source AS
SELECT 'keep' AS id, 'reader' AS source, 'same' AS content, NULL::VARCHAR AS nullable
UNION ALL SELECT 'update', 'reader', 'new', NULL
UNION ALL SELECT 'insert', 'reader', 'same', NULL
UNION ALL SELECT 'insert-duplicate-content', 'reader', 'same', NULL
UNION ALL SELECT 'null-to-value', 'reader', 'set', NULL
UNION ALL SELECT 'value-to-null', 'reader', NULL, NULL;

CREATE OR REPLACE TEMP TABLE stream_merge_before AS
SELECT s.id FROM stream_merge_source AS s ANTI JOIN stream_merge_target AS t USING (id)
UNION ALL
SELECT s.id FROM stream_merge_source AS s JOIN stream_merge_target AS t USING (id) WHERE t IS DISTINCT FROM s
UNION ALL
SELECT t.id FROM stream_merge_target AS t ANTI JOIN stream_merge_source AS s USING (id);
MERGE INTO stream_merge_target AS dst
USING stream_merge_source AS src
ON dst.id = src.id
WHEN MATCHED AND dst IS DISTINCT FROM src THEN UPDATE BY NAME
WHEN NOT MATCHED THEN INSERT BY NAME
WHEN NOT MATCHED BY SOURCE THEN DELETE;

CREATE OR REPLACE TEMP TABLE stream_merge_after_first AS
SELECT s.id FROM stream_merge_source AS s ANTI JOIN stream_merge_target AS t USING (id)
UNION ALL
SELECT s.id FROM stream_merge_source AS s JOIN stream_merge_target AS t USING (id) WHERE t IS DISTINCT FROM s
UNION ALL
SELECT t.id FROM stream_merge_target AS t ANTI JOIN stream_merge_source AS s USING (id);
MERGE INTO stream_merge_target AS dst
USING stream_merge_source AS src
ON dst.id = src.id
WHEN MATCHED AND dst IS DISTINCT FROM src THEN UPDATE BY NAME
WHEN NOT MATCHED THEN INSERT BY NAME
WHEN NOT MATCHED BY SOURCE THEN DELETE;
CREATE OR REPLACE TEMP TABLE stream_merge_after_second AS
SELECT s.id FROM stream_merge_source AS s ANTI JOIN stream_merge_target AS t USING (id)
UNION ALL
SELECT s.id FROM stream_merge_source AS s JOIN stream_merge_target AS t USING (id) WHERE t IS DISTINCT FROM s
UNION ALL
SELECT t.id FROM stream_merge_target AS t ANTI JOIN stream_merge_source AS s USING (id);

WITH summary AS (
    SELECT 'before' AS phase, count(1) AS mutations FROM stream_merge_before
    UNION ALL SELECT 'after_first', count(1) FROM stream_merge_after_first
    UNION ALL SELECT 'after_second', count(1) FROM stream_merge_after_second
    UNION ALL SELECT 'target_rows', count(1) FROM stream_merge_target
), checks AS (
    SELECT CASE WHEN phase = 'before' AND mutations = 6 THEN true
                WHEN phase IN ('after_first', 'after_second') AND mutations = 0 THEN true
                WHEN phase = 'target_rows' AND mutations = 6 THEN true ELSE false END AS passed
    FROM summary
    UNION ALL SELECT count(1) = 1 FROM stream_merge_target
        WHERE id = 'null-to-value' AND content = 'set' AND nullable IS NULL
    UNION ALL SELECT count(1) = 1 FROM stream_merge_target
        WHERE id = 'value-to-null' AND content IS NULL AND nullable IS NULL
)
SELECT CASE WHEN bool_and(passed)
            THEN 'pass: source column binds and second merge is a no-op'
            ELSE error('agent stream merge regression') END AS verification
FROM checks;

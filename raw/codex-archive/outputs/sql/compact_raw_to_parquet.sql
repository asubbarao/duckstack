-- End-of-day raw compaction.
--
-- Every source run remains as an immutable NDJSON object. This query rebuilds
-- one complete day's derived Parquet partitions, making the job idempotent
-- without mutating or deleting the raw objects.
--
-- Optional override:
--   COMPACT_DATE=2026-09-16 duckdb :memory: < outputs/sql/compact_raw_to_parquet.sql

.bail on

SET VARIABLE compact_date = coalesce(
    try_cast(nullif(getenv('COMPACT_DATE'), '') AS DATE),
    current_date
);

COPY (
    SELECT
        fetched_at::DATE AS fetched_date,
        *
    FROM read_json(
        'outputs/raw/slack/*.ndjson',
        format := 'newline_delimited',
        union_by_name := true,
        maximum_depth := -1,
        sample_size := -1,
        maximum_object_size := 67108864
    )
    WHERE fetched_at::DATE = getvariable('compact_date')
)
TO 'outputs/lake/raw_api_responses'
WITH (
    FORMAT parquet,
    PARTITION_BY (fetched_date, source_id, resource),
    COMPRESSION zstd,
    COMPRESSION_LEVEL 3,
    OVERWRITE_OR_IGNORE,
    FILENAME_PATTERN 'part_{uuidv7}'
);

DESCRIBE SELECT *
FROM read_parquet(
    'outputs/lake/raw_api_responses/**/*.parquet',
    hive_partitioning := true,
    union_by_name := true
);

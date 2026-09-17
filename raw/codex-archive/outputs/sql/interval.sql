-- UTC yesterday by default. Scheduler sets WINDOW_START/WINDOW_END for one
-- hour or day. Inclusive start, exclusive end. No multi-day backfill here.
CREATE OR REPLACE VIEW ingestion_interval AS
WITH bounds AS (
    SELECT
        coalesce(nullif(getenv('WINDOW_START'), '')::TIMESTAMPTZ,
            (date_trunc('day', current_timestamp AT TIME ZONE 'UTC')
                - INTERVAL 1 DAY) AT TIME ZONE 'UTC') AS window_start,
        coalesce(nullif(getenv('WINDOW_END'), '')::TIMESTAMPTZ,
            date_trunc('day', current_timestamp AT TIME ZONE 'UTC')
                AT TIME ZONE 'UTC') AS window_end
)
SELECT * FROM bounds
WHERE CASE WHEN window_end > window_start
    AND window_end - window_start <= INTERVAL 1 DAY THEN true
    ELSE error('Provide a positive WINDOW_START/WINDOW_END interval of at most 24 hours') END;

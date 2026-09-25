-- Run once per profile with an ephemeral client, for example:
--   DUCKSTACK_PROFILE=team DUCKSTACK_PRODUCER_ID=test-device duckdb :memory: \
--     -f server/resource_profile.sql -f tests/resource_profile.sql
--   DUCKSTACK_PROFILE=personal DUCKSTACK_PRODUCER_ID=test-device duckdb :memory: \
--     -f server/resource_profile.sql -f tests/resource_profile.sql
-- Optional-memory cases are invoked by setting DUCKSTACK_MEMORY_GIB to each
-- allowed value before launching the same command.
-- Rejection checks should exit nonzero:
--   DUCKSTACK_PROFILE=unknown DUCKSTACK_PRODUCER_ID=test-device duckdb :memory: -f server/resource_profile.sql
--   DUCKSTACK_PROFILE=team DUCKSTACK_PRODUCER_ID=test-device DUCKSTACK_MEMORY_GIB=16 duckdb :memory: -f server/resource_profile.sql
--   DUCKSTACK_PROFILE=team duckdb :memory: -f server/resource_profile.sql

SELECT CASE
         WHEN getenv('DUCKSTACK_PROFILE') = 'team'
          AND current_setting('threads')::INTEGER = 2
          AND current_setting('memory_limit') = coalesce(nullif(getenv('DUCKSTACK_MEMORY_GIB'), ''), '4') || '.0 GiB'
          AND try_cast(coalesce(nullif(getenv('DUCKSTACK_MEMORY_GIB'), ''), '4') AS INTEGER) IN (4, 6, 8)
          THEN 'team profile passed'
         WHEN getenv('DUCKSTACK_PROFILE') = 'personal'
          AND current_setting('threads')::INTEGER = 10
          AND current_setting('memory_limit') = coalesce(nullif(getenv('DUCKSTACK_MEMORY_GIB'), ''), '24') || '.0 GiB'
          AND try_cast(coalesce(nullif(getenv('DUCKSTACK_MEMORY_GIB'), ''), '24') AS INTEGER) IN (16, 24)
          THEN 'personal profile passed'
         ELSE error('resource profile default assertion failed')
       END AS test_result;

SELECT CASE
         WHEN nullif(getenv('DUCKSTACK_MEMORY_GIB'), '') IS NOT NULL
          AND current_setting('memory_limit') = getenv('DUCKSTACK_MEMORY_GIB') || '.0 GiB' THEN 'override passed'
         WHEN nullif(getenv('DUCKSTACK_MEMORY_GIB'), '') IS NULL THEN 'default selected'
         ELSE error('resource profile override assertion failed')
       END AS override_test_result;

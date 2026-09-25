-- Resource profile for a Duckstack DuckDB process. Include this at process startup,
-- before any configuration lock; never run it against an already-running dev service.
-- The caller must select both a profile and producer identity explicitly.

SELECT CASE
         WHEN nullif(getenv('DUCKSTACK_PROFILE'), '') IN ('team', 'personal') THEN true
         ELSE error('DUCKSTACK_PROFILE must be explicitly set to team or personal')
       END AS profile_is_valid;

SELECT CASE
         WHEN nullif(getenv('DUCKSTACK_PRODUCER_ID'), '') IS NOT NULL THEN true
         ELSE error('DUCKSTACK_PRODUCER_ID must be explicitly set; do not infer a producer identity')
       END AS producer_is_valid;

SELECT CASE
         WHEN nullif(getenv('DUCKSTACK_MEMORY_GIB'), '') IS NULL THEN true
         WHEN try_cast(getenv('DUCKSTACK_MEMORY_GIB') AS INTEGER) IS NULL THEN error('DUCKSTACK_MEMORY_GIB must be an integer')
         WHEN getenv('DUCKSTACK_PROFILE') = 'team'
          AND try_cast(getenv('DUCKSTACK_MEMORY_GIB') AS INTEGER) IN (4, 6, 8) THEN true
         WHEN getenv('DUCKSTACK_PROFILE') = 'personal'
          AND try_cast(getenv('DUCKSTACK_MEMORY_GIB') AS INTEGER) IN (16, 24) THEN true
         ELSE error('DUCKSTACK_MEMORY_GIB is outside the selected profile allowance')
       END AS memory_is_valid;

SET GLOBAL memory_limit = CASE
  WHEN nullif(getenv('DUCKSTACK_PRODUCER_ID'), '') IS NULL
    THEN error('DUCKSTACK_PRODUCER_ID is required before applying a resource profile')
  WHEN getenv('DUCKSTACK_PROFILE') NOT IN ('team', 'personal')
    THEN error('DUCKSTACK_PROFILE must be explicitly set to team or personal')
  WHEN nullif(getenv('DUCKSTACK_MEMORY_GIB'), '') IS NULL AND getenv('DUCKSTACK_PROFILE') = 'team' THEN '4GiB'
  WHEN nullif(getenv('DUCKSTACK_MEMORY_GIB'), '') IS NULL AND getenv('DUCKSTACK_PROFILE') = 'personal' THEN '24GiB'
  WHEN getenv('DUCKSTACK_PROFILE') = 'team'
   AND try_cast(getenv('DUCKSTACK_MEMORY_GIB') AS INTEGER) IN (4, 6, 8)
    THEN getenv('DUCKSTACK_MEMORY_GIB') || 'GiB'
  WHEN getenv('DUCKSTACK_PROFILE') = 'personal'
   AND try_cast(getenv('DUCKSTACK_MEMORY_GIB') AS INTEGER) IN (16, 24)
    THEN getenv('DUCKSTACK_MEMORY_GIB') || 'GiB'
  ELSE error('DUCKSTACK_MEMORY_GIB is outside the selected profile allowance')
END;

SET GLOBAL threads = CASE
  WHEN nullif(getenv('DUCKSTACK_PRODUCER_ID'), '') IS NULL
    THEN error('DUCKSTACK_PRODUCER_ID is required before applying a resource profile')
  WHEN getenv('DUCKSTACK_PROFILE') = 'team' THEN 2
  WHEN getenv('DUCKSTACK_PROFILE') = 'personal' THEN 10
  ELSE error('DUCKSTACK_PROFILE must be explicitly set to team or personal')
END;

SELECT getenv('DUCKSTACK_PROFILE') AS profile,
       getenv('DUCKSTACK_PRODUCER_ID') AS producer_id,
       current_setting('memory_limit') AS memory_limit,
       current_setting('threads') AS threads;

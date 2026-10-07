-- cron.sql: every scheduled job. A job posts its file's CURRENT text to /sql (post_file, in live.sql), so editing
-- the file changes the next run with no restart and no re-registration.
-- cron(query VARCHAR, schedule VARCHAR: 6 fields, seconds first) -> job id
.read /Users/aloksubbarao/duckdb-skills/server/ext_catalog.sql
.read /Users/aloksubbarao/duckdb-skills/readthedocs_catalog.sql
.read /Users/aloksubbarao/duckdb-skills/server/open_prs.sql
SELECT cron('FROM post_file(' || chr(39) || '/Users/aloksubbarao/duckdb-skills/server/' || file || chr(39) || ')', schedule) AS job
FROM (SELECT 'live.sql' AS file, '30 * * * * *' AS schedule
      UNION ALL SELECT 'open_prs.sql', '0 7 * * * *'
      UNION ALL SELECT '../readthedocs_catalog.sql', '20 * * * * *');
.read /Users/aloksubbarao/duckdb-skills/server/agent_stream_schedule.sql
.read /Users/aloksubbarao/duckdb-skills/server/ext_catalog_schedule.sql

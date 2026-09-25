-- Add this program to agents.lake_programs as catalog_register, then install this
-- job beside the publisher's existing two-minute job. Catalog outages are retried;
-- registration begins with DuckLake metadata reconciliation before any add call.
WITH programs AS (
  SELECT $job$
    WITH calls AS (
      SELECT http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql',sql)) AS response
      FROM agents.lake_programs WHERE name='catalog_register'
    )
    SELECT CASE WHEN response.status::INTEGER=200 THEN from_json(response.body, '"VARCHAR"')
                ELSE error(response::VARCHAR) END AS receipt
    FROM calls;
  $job$ AS sql
), missing AS (
  SELECT sql FROM programs
  WHERE (trim(sql), '15 */2 * * * *') NOT IN (SELECT trim(query), schedule FROM cron_jobs())
), statements AS (
  SELECT printf('SELECT cron(%s, ''15 */2 * * * *'') AS job_id;',
                chr(39)||replace(sql,chr(39),chr(39)||chr(39))||chr(39)) AS statement
  FROM missing
), fired AS (
  SELECT http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql',statement)) AS response
  FROM statements
)
SELECT CASE WHEN response.status::INTEGER=200 THEN from_json(response.body, '"VARCHAR"')
            ELSE error(response::VARCHAR) END AS registration
FROM fired;

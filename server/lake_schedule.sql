-- Optional, explicit opt-in after the reference-machine acceptance checks.
-- No additional service: cronjob runs the banked publisher every two minutes.
-- Empty queues spawn no shell/AWS work. Failed records stop after five attempts;
-- conflicts never retry automatically. Re-running registration is a no-op.
WITH programs AS (
 SELECT $job$
 WITH calls AS (
 SELECT http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql',sql)) AS response
 FROM agents.lake_programs WHERE name='publish'
 ) SELECT CASE WHEN response.status::INTEGER=200 THEN from_json(response.body, '"VARCHAR"')
 ELSE error(response::VARCHAR) END AS receipt FROM calls;
 $job$ AS sql
), missing AS (
 SELECT sql FROM programs WHERE (trim(sql), '0 */2 * * * *') NOT IN
   (SELECT trim(query), schedule FROM cron_jobs())
), statements AS (
 SELECT printf('SELECT cron(%s, ''0 */2 * * * *'') AS job_id;',
   chr(39)||replace(sql,chr(39),chr(39)||chr(39))||chr(39)) AS statement FROM missing
), fired AS (
 SELECT http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql',statement)) AS response FROM statements
)
SELECT CASE WHEN response.status::INTEGER=200 THEN from_json(response.body, '"VARCHAR"')
            ELSE error(response::VARCHAR) END AS registration FROM fired;

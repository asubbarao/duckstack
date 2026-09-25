-- Run this as an ephemeral client FROM THE REPOSITORY ROOT after local setup.
-- Source code (not credentials) is banked on the selected dev for MCP + cron.
INSTALL http_client FROM community; LOAD http_client;
CREATE TEMP TABLE lake_program_sources AS
SELECT CASE WHEN ends_with(filename, 'lake_publish.sql') THEN 'publish' ELSE 'refresh_aws' END AS name,
       content AS sql
FROM read_text(['server/lake_publish.sql', 'server/lake_aws_credentials.sql']);

CREATE TEMP TABLE lake_program_receipts AS
WITH statements AS (
 SELECT printf($sql$
   CREATE TABLE IF NOT EXISTS agents.lake_programs (name VARCHAR PRIMARY KEY, sql VARCHAR NOT NULL);
   INSERT INTO agents.lake_programs BY NAME SELECT '%s' AS name, '%s' AS sql
   ON CONFLICT(name) DO UPDATE SET sql=excluded.sql;
 $sql$, name, replace(sql, chr(39), chr(39)||chr(39))) AS statement FROM lake_program_sources
)
SELECT http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql', statement)) AS response
FROM statements;
SELECT CASE WHEN response.status::INTEGER = 200 THEN true ELSE error(response::VARCHAR) END AS installed
FROM lake_program_receipts;

WITH registrations AS (
 SELECT $register$
 PRAGMA mcp_publish_tool('lake_publish',
 'Publish up to 10 approved local outbox records. Conditional S3 writes, byte verification, durable receipts; five attempts maximum. Conflicts are retained, never overwritten.',
 $body$WITH calls AS (
 SELECT http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql', sql)) AS response
 FROM agents.lake_programs WHERE name='publish'
 ) SELECT response.status AS executor_status, from_json(response.body, '"VARCHAR"') AS receipt_json FROM calls$body$,
 '{}','[]','markdown');
 PRAGMA mcp_publish_tool('lake_refresh_aws',
 'Refresh the scoped developer-lake DuckDB secret from the current AWS CLI login. Run aws login first if expired. Credential values are not returned.',
 $body$WITH calls AS (
 SELECT http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql', sql)) AS response
 FROM agents.lake_programs WHERE name='refresh_aws'
 ) SELECT response.status AS executor_status, from_json(response.body, '"VARCHAR"') AS receipt_json FROM calls$body$,
 '{}','[]','markdown');
 $register$ AS statement
), calls AS (
 SELECT http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql',statement)) AS response FROM registrations
)
SELECT CASE WHEN response.status::INTEGER = 200 THEN true ELSE error(response::VARCHAR) END AS tools_registered FROM calls;

-- Bank restore programs over Quack: their bodies exceed the HTTP SQL-field limit.
-- QUACK_TOKEN must be provided by the operator as an environment variable.
LOAD quack; LOAD scalarfs;
COPY (
 SELECT string_agg(printf('INSERT INTO agents.lake_programs BY NAME SELECT ''%s'' AS name, ''%s'' AS sql ON CONFLICT(name) DO UPDATE SET sql=excluded.sql;',
   CASE WHEN ends_with(filename,'lake_local.sql') THEN 'local_tools'
        WHEN ends_with(filename,'lake_shared.sql') THEN 'shared_tools' ELSE 'publisher_tools' END,
   replace(content,chr(39),chr(39)||chr(39))), chr(10))
 FROM read_text(['server/lake_local.sql','server/lake_shared.sql','server/lake_tools.sql'])
) TO 'variable:lake_bank' (FORMAT variable, LIST none);
FROM quack_query('quack:localhost:9494', getvariable('lake_bank'), token:=getenv('QUACK_TOKEN'));

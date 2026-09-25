-- Restore publisher/credential tools from durable SQL programs; no file-path dependency.
PRAGMA mcp_publish_tool('lake_publish',
 'Publish up to 10 approved outbox records with conditional S3 writes, byte verification and durable receipts. Five attempts maximum; conflicts never overwrite.',
 $body$WITH calls AS (
 SELECT http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql',sql)) AS response
 FROM agents.lake_programs WHERE name='publish'
 ) SELECT response.status AS executor_status, from_json(response.body, '"VARCHAR"') AS receipt_json FROM calls$body$,
 '{}','[]','markdown');
PRAGMA mcp_publish_tool('lake_register',
 'Reconcile already-published S3 Parquet and manifests into the shared developer DuckLake. Requires a current AWS login and catalog tunnel; does not upload local objects.',
 $body$WITH calls AS (
 SELECT http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql',sql)) AS response
 FROM agents.lake_programs WHERE name='catalog_register'
 ) SELECT response.status AS executor_status, from_json(response.body, '"VARCHAR"') AS receipt_json FROM calls$body$,
 '{}','[]','markdown');
PRAGMA mcp_publish_tool('lake_refresh_aws',
 'Refresh the scoped lake secret from the current AWS login. Credentials are never returned. Run aws login first when expired.',
 $body$WITH calls AS (
 SELECT http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql',sql)) AS response
 FROM agents.lake_programs WHERE name='refresh_aws'
 ) SELECT response.status AS executor_status, from_json(response.body, '"VARCHAR"') AS receipt_json FROM calls$body$,
 '{}','[]','markdown');

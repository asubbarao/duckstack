-- Public SQL routes preserve explicit limits; other top-level SELECTs default to 3, unless the MCP-generated
-- leading request comment carries no_limit=true (query_no_limit sets it, so its "no cap" is true).
-- Only the MCP-generated leading request comment is retained as transport provenance.
INSTALL quackapi FROM community; LOAD quackapi;
-- Opt-in incubator SQL executor and typed browser-capture handoff.
.read /Users/aloksubbarao/incubator/relational-acquisition/sql/routes.sql
.read /Users/aloksubbarao/incubator/relational-acquisition/tests/routes.sql
CREATE SCHEMA IF NOT EXISTS agents;
CREATE OR REPLACE VIEW agents.path_aliases AS
SELECT 'asubbarao.github' AS alias, 'ASUBBARAO_GITHUB_ROOT' AS environment_variable,
       'git://' || nullif(getenv('ASUBBARAO_GITHUB_ROOT'), '') AS root;
FROM quack_query(getvariable('quack_uri'),
  replace(replace($routes$
CREATE OR REPLACE ROUTE sql POST '/sql'
  AS SELECT * FROM quack_query('@QUACK_URI', $session$SET enable_profiling = 'no_output';
SET profiling_coverage = 'ALL';
SET VARIABLE "asubbarao.github" = 'git://' || nullif(getenv('ASUBBARAO_GITHUB_ROOT'), '');
$session$ || CASE WHEN starts_with($sql, '/* request_id=') THEN left($sql, strpos($sql, chr(10))) ELSE '' END ||
coalesce(array_to_string(list_transform(try(parse_statements($sql)), s ->
 CASE WHEN (CASE WHEN starts_with($sql, '/* request_id=') THEN contains(left($sql, strpos($sql, chr(10))), 'no_limit=true') ELSE false END) THEN s
   WHEN coalesce(json_serialize_sql(s)->>'error' = 'false'
   AND len(list_filter(json_extract(json_serialize_sql(s), '$.statements[0].node.modifiers[*].limit'), x -> x <> 'null'::JSON)) = 0, false)
 THEN printf('SELECT * FROM (%s) AS agent_result LIMIT 3', s) ELSE s END), ';' || chr(10)), $sql), token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE ROUTE query POST '/query'
  AS SELECT * FROM quack_query('@QUACK_URI', $session$SET enable_profiling = 'no_output';
SET profiling_coverage = 'ALL';
SET VARIABLE "asubbarao.github" = 'git://' || nullif(getenv('ASUBBARAO_GITHUB_ROOT'), '');
$session$ || CASE WHEN starts_with($sql, '/* request_id=') THEN left($sql, strpos($sql, chr(10))) ELSE '' END ||
coalesce(array_to_string(list_transform(try(parse_statements($sql)), s ->
 CASE WHEN (CASE WHEN starts_with($sql, '/* request_id=') THEN contains(left($sql, strpos($sql, chr(10))), 'no_limit=true') ELSE false END) THEN s
   WHEN coalesce(json_serialize_sql(s)->>'error' = 'false'
   AND len(list_filter(json_extract(json_serialize_sql(s), '$.statements[0].node.modifiers[*].limit'), x -> x <> 'null'::JSON)) = 0, false)
 THEN printf('SELECT * FROM (%s) AS agent_result LIMIT 3', s) ELSE s END), ';' || chr(10)), $sql), token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE ROUTE otlp_logs POST '/v1/logs' AS
  COPY (SELECT $body::VARCHAR AS payload, 'logs' AS signal) TO '@OTLP_DIR'
  (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', PARTITION_BY (signal), FILENAME_PATTERN '{uuid}', FILE_EXTENSION 'json', OVERWRITE_OR_IGNORE true);
CREATE OR REPLACE ROUTE otlp_traces POST '/v1/traces' AS
  COPY (SELECT $body::VARCHAR AS payload, 'traces' AS signal) TO '@OTLP_DIR'
  (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', PARTITION_BY (signal), FILENAME_PATTERN '{uuid}', FILE_EXTENSION 'json', OVERWRITE_OR_IGNORE true);
CREATE OR REPLACE ROUTE otlp_metrics POST '/v1/metrics' AS
  COPY (SELECT $body::VARCHAR AS payload, 'metrics' AS signal) TO '@OTLP_DIR'
  (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', PARTITION_BY (signal), FILENAME_PATTERN '{uuid}', FILE_EXTENSION 'json', OVERWRITE_OR_IGNORE true);
-- One empty payload per signal, so the unified view binds on a fresh instance (a glob that
-- matches nothing fails CREATE VIEW); it reads as zero rows.
COPY (SELECT '{"resourceLogs":[]}' AS payload, 'logs' AS signal
      UNION ALL SELECT '{"resourceSpans":[]}', 'traces'
      UNION ALL SELECT '{"resourceMetrics":[]}', 'metrics')
TO '@OTLP_DIR' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', PARTITION_BY (signal),
                FILENAME_PATTERN '_seed', FILE_EXTENSION 'json', OVERWRITE_OR_IGNORE true);
SELECT 'routes ok' AS routes
$routes$, '@QUACK_URI', getvariable('quack_uri')), '@OTLP_DIR', getvariable('otlp_dir')),
  token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE TABLE _quackapi_serve AS
SELECT now() AS started_at, * FROM quackapi_serve(getvariable('quackapi_port'), host := '127.0.0.1');

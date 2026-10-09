-- Run on dev after live.sql. A counter inside each dispatched SELECT proves filter placement.
CREATE SCHEMA IF NOT EXISTS agent_scratch;
DROP VIEW IF EXISTS agent_scratch.hostfs_filter_probe;
DROP SEQUENCE IF EXISTS agent_scratch.hostfs_filter_calls;
CREATE SEQUENCE agent_scratch.hostfs_filter_calls;

CREATE OR REPLACE TEMP TABLE hostfs_probe_setup AS
SELECT http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type':'application/json'},
 json_object('sql', 'CREATE OR REPLACE VIEW agent_scratch.hostfs_filter_probe AS ' ||
 replace(string_split(content, 'CREATE OR REPLACE VIEW hostfs_ls AS')[2],
 'SELECT coalesce(array_agg',
 'SELECT nextval(' || chr(39) || 'agent_scratch.hostfs_filter_calls' || chr(39) ||
 ') AS probe_call, coalesce(array_agg'))) AS receipt
FROM read_text('/Users/aloksubbarao/duckdb-skills/server/live.sql');

CREATE OR REPLACE TEMP TABLE hostfs_probe_rows AS
SELECT * FROM agent_scratch.hostfs_filter_probe
WHERE folder = getenv('HOME') || '/duckdb-skills';

CREATE OR REPLACE TEMP TABLE hostfs_probe_selected_calls AS
SELECT last_value FROM duckdb_sequences()
WHERE schema_name = 'agent_scratch' AND sequence_name = 'hostfs_filter_calls';

CREATE OR REPLACE TEMP TABLE hostfs_probe_absent AS
SELECT * FROM agent_scratch.hostfs_filter_probe
WHERE folder = '/nonexistent-unregistered-hostfs-filter-probe';

CREATE OR REPLACE TEMP TABLE hostfs_probe_final_calls AS
SELECT last_value FROM duckdb_sequences()
WHERE schema_name = 'agent_scratch' AND sequence_name = 'hostfs_filter_calls';

DROP VIEW agent_scratch.hostfs_filter_probe;
DROP SEQUENCE agent_scratch.hostfs_filter_calls;

SELECT 'one selected folder dispatches once' AS test,
 CASE WHEN last_value = 1 THEN true ELSE error('selected folder dispatched extra listings') END AS passed
FROM hostfs_probe_selected_calls
UNION ALL
SELECT 'unknown folder dispatches nothing',
 CASE WHEN last_value = 1 THEN true ELSE error('unknown folder dispatched a listing') END
FROM hostfs_probe_final_calls
UNION ALL
SELECT 'listing returns successful file rows',
 CASE WHEN count(path) > 0 AND bool_and(status = 200 AND error IS NULL)
 THEN true ELSE error('listing did not return successful file rows') END
FROM hostfs_probe_rows;

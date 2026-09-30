-- Full reader schema; downstream queries choose their own projections and grain.
LOAD quack;
-- A restarted reader invalidates the old Quack connection.
DROP VIEW IF EXISTS agent.conversations;
DETACH DATABASE IF EXISTS agent_reader;
ATTACH 'quack:127.0.0.1:19494' AS agent_reader
    (TYPE quack, TOKEN getenv('QUACK_TOKEN'));
CREATE SCHEMA IF NOT EXISTS agent;
CREATE OR REPLACE VIEW agent.conversations AS
SELECT * FROM agent_reader.main.conversations;

CREATE OR REPLACE VIEW agent.reader_build AS
FROM quack_query('quack:127.0.0.1:19494',
    $$SELECT extension_name, extension_version FROM duckdb_extensions() WHERE extension_name = 'agent_data'$$,
    token := getenv('QUACK_TOKEN'));

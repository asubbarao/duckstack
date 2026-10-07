-- The native reader is used by ingestion; public conversations are the sanitized cache.
LOAD quack;
DETACH DATABASE IF EXISTS agent_reader;
CREATE SCHEMA IF NOT EXISTS agent;

CREATE OR REPLACE VIEW agent.reader_build AS
FROM quack_query('quack:127.0.0.1:19494',
    $$SELECT extension_name, extension_version FROM duckdb_extensions() WHERE extension_name = 'agent_data'$$,
    token := getenv('QUACK_TOKEN'));

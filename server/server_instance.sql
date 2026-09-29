-- One identity for the process lifetime, shared by native logs and its supervisor.
CREATE SCHEMA IF NOT EXISTS meta;
CREATE TABLE IF NOT EXISTS meta.server_instances (
    instance_id VARCHAR PRIMARY KEY, started_at TIMESTAMPTZ, wrapper_pid BIGINT,
    engine_version VARCHAR, extensions JSON, native_log_path VARCHAR
);
INSERT INTO meta.server_instances BY NAME
SELECT coalesce(nullif(getenv('QUACK_INSTANCE_ID'), ''), 'legacy') AS instance_id,
       now() AS started_at,
       try_cast(getenv('QUACK_WRAPPER_PID') AS BIGINT) AS wrapper_pid,
       version() AS engine_version, to_json(list(e)) AS extensions,
       coalesce(nullif(getenv('QUACK_NATIVE_LOG'), ''),
                getenv('HOME') || '/.duck/logs/duckdb_log.csv') AS native_log_path
FROM duckdb_extensions() e WHERE loaded
ON CONFLICT DO NOTHING;

CREATE OR REPLACE VIEW meta.current_server AS
FROM meta.server_instances
QUALIFY row_number() OVER (ORDER BY started_at DESC) = 1;

-- Filled by setup.sql after the listeners are chosen.  MCP exposes this relation so an
-- agent can identify the exact disposable instance it reached instead of assuming ports.
CREATE TABLE IF NOT EXISTS meta.runtime_endpoints (
    service VARCHAR PRIMARY KEY, address VARCHAR, recorded_at TIMESTAMPTZ
);

-- Local Prometheus + Grafana in agents. Happy path needs NO AWS.
-- Store: quack MCP file ~/.duck/dev.duckdb (agents schema).
-- Apply via MCP `sql` (dev → http://localhost:9496/mcp) or quack_query to :9494.
-- No .py / bank sidecars. Schemas: main + agents only; leave raw alone.
-- setup.sql already: INSTALL prometheus FROM community; LOAD prometheus;

CREATE SCHEMA IF NOT EXISTS agents;

CREATE TABLE IF NOT EXISTS agents.prometheus_endpoints (
  name VARCHAR PRIMARY KEY,
  endpoint VARCHAR NOT NULL,
  kind VARCHAR NOT NULL DEFAULT 'prometheus',
  region VARCHAR,
  auth_mode VARCHAR DEFAULT 'none',
  is_default BOOLEAN DEFAULT false,
  notes VARCHAR,
  writer VARCHAR DEFAULT 'alok',
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS agents.grafana_datasources (
  name VARCHAR PRIMARY KEY,
  uid VARCHAR,
  type VARCHAR NOT NULL DEFAULT 'prometheus',
  url VARCHAR NOT NULL,
  prometheus_endpoint_name VARCHAR,
  is_default BOOLEAN DEFAULT false,
  notes VARCHAR,
  writer VARCHAR DEFAULT 'alok',
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS agents.grafana_instances (
  name VARCHAR PRIMARY KEY,
  base_url VARCHAR NOT NULL,
  access_mode VARCHAR NOT NULL DEFAULT 'direct',
  ec2_instance_id VARCHAR,
  region VARCHAR,
  is_default BOOLEAN DEFAULT false,
  notes VARCHAR,
  writer VARCHAR DEFAULT 'alok',
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS agents.prometheus_grafana_findings (
  topic VARCHAR,
  detail VARCHAR,
  source VARCHAR,
  writer VARCHAR DEFAULT 'alok',
  observed_at TIMESTAMPTZ DEFAULT now()
);

INSERT OR REPLACE INTO agents.prometheus_endpoints BY NAME
SELECT * FROM (VALUES
  ('local', 'http://127.0.0.1:9090', 'prometheus', NULL, 'none', true,
   'Local Prometheus (brew services start prometheus)', 'alok', now())
) AS v(name, endpoint, kind, region, auth_mode, is_default, notes, writer, updated_at);

INSERT OR REPLACE INTO agents.grafana_datasources BY NAME
SELECT * FROM (VALUES
  ('local_prom', 'local-prom', 'prometheus', 'http://127.0.0.1:9090', 'local', true,
   'Grafana datasource → local Prometheus', 'alok', now())
) AS v(name, uid, type, url, prometheus_endpoint_name, is_default, notes, writer, updated_at);

INSERT OR REPLACE INTO agents.grafana_instances BY NAME
SELECT * FROM (VALUES
  ('local_brew', 'http://127.0.0.1:3000', 'direct', NULL, NULL, true,
   'Homebrew Grafana (brew services start grafana)', 'alok', now())
) AS v(name, base_url, access_mode, ec2_instance_id, region, is_default, notes, writer, updated_at);

DELETE FROM agents.prometheus_endpoints WHERE name = 'aws_amp' OR endpoint ILIKE '%REPLACE_WORKSPACE%';
DELETE FROM agents.grafana_datasources WHERE name = 'aws_grafana_prom' OR url ILIKE '%REPLACE_WORKSPACE%';
DELETE FROM agents.grafana_instances WHERE name = 'inframe_prod_ec2' OR access_mode = 'ssm_port_forward';

CREATE OR REPLACE MACRO agents.prom_endpoint() AS (
  SELECT endpoint FROM agents.prometheus_endpoints WHERE is_default ORDER BY updated_at DESC LIMIT 1
);

CREATE OR REPLACE MACRO agents.prom_query(q, ep := 'http://127.0.0.1:9090') AS TABLE
  SELECT * FROM prometheus_query(q, endpoint := ep);

CREATE OR REPLACE MACRO agents.prom_scan(q, t0, t1, ep := 'http://127.0.0.1:9090', step := INTERVAL 1 MINUTE) AS TABLE
  SELECT * FROM prometheus_scan(q, t0, t1, step := step, endpoint := ep);

CREATE OR REPLACE VIEW agents.prometheus_endpoints_v AS
SELECT * FROM agents.prometheus_endpoints;

CREATE OR REPLACE VIEW agents.grafana_datasources_v AS
SELECT g.*, e.endpoint AS resolved_prometheus_endpoint
FROM agents.grafana_datasources g
LEFT JOIN agents.prometheus_endpoints e ON e.name = g.prometheus_endpoint_name;

CREATE OR REPLACE VIEW agents.grafana_instances_v AS
SELECT * FROM agents.grafana_instances;

CREATE OR REPLACE VIEW agents.obs_summary AS
SELECT 'prometheus_endpoint' AS kind, name, endpoint AS url, is_default, notes
FROM agents.prometheus_endpoints
UNION ALL
SELECT 'grafana_datasource' AS kind, name, url, is_default, notes FROM agents.grafana_datasources
UNION ALL
SELECT 'grafana_instance' AS kind, name, base_url AS url, is_default, notes FROM agents.grafana_instances;

DELETE FROM agents.prometheus_grafana_findings WHERE topic IN ('local.happy_path','ext_catalog.prometheus','ext_catalog.grafana','inframe.amp_grafana','mac.endpoints');
INSERT INTO agents.prometheus_grafana_findings BY NAME
SELECT * FROM (VALUES
  ('local.happy_path',
   'No AWS required. brew prometheus :9090 + brew grafana :3000 + agents.prom_query via MCP/quack.',
   'alok/local-prom-grafana worktree', 'alok', now()),
  ('ext_catalog.prometheus',
   'botan/duckdb-prometheus — prometheus_query/scan/series/labels/metadata. Unauthenticated HTTP.',
   'agents.ext_catalog', 'alok', now()),
  ('ext_catalog.grafana',
   'No grafana DuckDB extension; wire instances/datasources in agents + HTTP/MCP.',
   'agents.ext_catalog', 'alok', now())
) AS v(topic, detail, source, writer, observed_at);

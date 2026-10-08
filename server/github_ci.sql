-- Open PRs by an author → their state → CI runs → failed runs' jobs and log lines, all read by gh
-- through shellfs into agents.gh_*. github_fetch.tera has one read per kind; github_dispatch.tera
-- is one stage (render every todo row of a kind, post each to /sql, keep the receipt). This file
-- renders the stages in dependency order and posts them as one ordered body. Run on 9495/sql.
-- The gh_* tables come from the first read of each kind (is_first); gh_todo reads them, so it is
-- created once they exist.
LOAD shellfs; LOAD tera; LOAD http_client;
CREATE SCHEMA IF NOT EXISTS agents;
CREATE TABLE IF NOT EXISTS agents.gh_dispatch (
  sent_at TIMESTAMPTZ, kind VARCHAR, ctx JSON, statement VARCHAR, status INTEGER, body VARCHAR);

-- What each kind still needs, derived from what the earlier kinds stored.
CREATE OR REPLACE VIEW agents.gh_todo AS
WITH author AS (SELECT 'asubbarao' AS author),
tables AS (SELECT table_name FROM duckdb_tables() WHERE schema_name = 'agents'),
pr AS (SELECT * FROM agents.gh_pr QUALIFY fetched_at = max(fetched_at) OVER ()),
pr_state AS (SELECT * FROM agents.gh_pr_state QUALIFY row_number() OVER (PARTITION BY repo, number ORDER BY fetched_at DESC) = 1),
failed_run AS (SELECT DISTINCT repo, databaseId AS run_id FROM agents.gh_run WHERE conclusion = 'failure'),
todo AS (
  SELECT 'pr' AS kind, json_object('author', author) AS ctx FROM author
  UNION ALL
  SELECT 'pr_state', json_object('repo', repository.nameWithOwner, 'number', number) FROM pr
  UNION ALL
  SELECT 'run', json_object('repo', repo, 'number', number, 'sha', headRefOid) FROM pr_state
  UNION ALL
  SELECT 'job', json_object('repo', repo, 'run_id', run_id) FROM failed_run
  UNION ALL
  SELECT 'log_line', json_object('repo', repo, 'run_id', run_id) FROM failed_run)
SELECT kind, ctx, ('gh_' || kind) NOT IN (SELECT table_name FROM tables)
                  AND row_number() OVER (PARTITION BY kind ORDER BY ctx::VARCHAR) = 1 AS is_first
FROM todo;

-- Each stage twice: the table-creating row first, then the rest. One body keeps the order.
WITH stage AS (
  SELECT 'pr' AS kind, 1 AS step UNION ALL SELECT 'pr_state', 2 UNION ALL SELECT 'run', 3
  UNION ALL SELECT 'job', 4 UNION ALL SELECT 'log_line', 5),
phase AS (SELECT true AS first UNION ALL SELECT false),
rendered AS (
  SELECT step, first, tera_render(content, json_object('kind', kind, 'first', first,
      'fetch_template', '/Users/aloksubbarao/duckdb-skills/server/github_fetch.tera',
      'sql_url', 'http://localhost:9495/sql'), autoescape := false) AS statement
  FROM stage CROSS JOIN phase
  CROSS JOIN read_text('/Users/aloksubbarao/duckdb-skills/server/github_dispatch.tera'))
SELECT http_post_form('http://localhost:9495/sql', MAP{}, MAP{'sql': string_agg(statement, ';' || chr(10) ORDER BY step, first DESC)}) AS receipt
FROM rendered;

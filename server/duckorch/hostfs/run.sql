-- Rebuild hostfs.scan and hostfs.content in this process with duckorch:
--   duckdb :memory: -f ~/duckdb-skills/server/duckorch/hostfs/run.sql
-- duckorch parses task SQL without extension syntax, so the self-dispatch route and its
-- server are set up here, before the DAG runs; every task posts to it.
LOAD duckorch;
LOAD hostfs;
LOAD http_client;
LOAD quackapi;
CREATE OR REPLACE ROUTE dispatch POST '/q' AS SELECT rows.* FROM query($q) rows;
FROM quackapi_serve(19504, host := '127.0.0.1');
PRAGMA orch_init;
PRAGMA orch_register('/Users/aloksubbarao/duckdb-skills/server/duckorch/hostfs/tasks/');
PRAGMA orch_run;
FROM quackapi_stop();
SELECT task_name, status, finished_at - started_at AS took, error_message[:200] AS error
FROM __orch__.runs ORDER BY started_at;

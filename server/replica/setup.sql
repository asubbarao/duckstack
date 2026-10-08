-- setup.sql: the staging replica DuckDB, the whole system. launchd (com.inframe.replica.plist, beside this file) runs
--   duckdb ~/.duck/replica/staging_replica.duckdb -cmd '.read ~/duckdb-skills/server/replica/setup.sql'
-- with stdin held open. The database file is disposable: delete it, restart, and this file plus the first pull
-- rebuild every table, view and route. Ports: quack 9510; quackapi 9511 (/sql, and /org/live + /org/replica once a
-- pull has landed). The source is attached READ_ONLY inside pull.sql; nothing here or there writes to Postgres.
.bail on
SET GLOBAL extension_directory = getenv('HOME') || '/.duck/extensions';
INSTALL quack; LOAD quack; INSTALL postgres; LOAD postgres; LOAD json; LOAD icu;
INSTALL quackapi FROM community; LOAD quackapi; INSTALL cronjob FROM community; LOAD cronjob;
INSTALL curl_httpfs FROM community; LOAD curl_httpfs;

-- A laptop tenant beside dev: bounded memory and cores, spill under ~/.duck/replica, UTC, no silent downloads.
SET GLOBAL memory_limit = '6GiB'; SET GLOBAL threads = 4; SET GLOBAL TimeZone = 'UTC';
SET GLOBAL httpfs_client_implementation = 'curl';
SET GLOBAL temp_directory = getenv('HOME') || '/.duck/replica/tmp'; SET GLOBAL max_temp_directory_size = '20GiB';
SET GLOBAL autoinstall_known_extensions = false;

-- Replicated tables keep their Postgres schema name, so one query text runs on pg.public.x (live) and public.x (copy).
CREATE SCHEMA IF NOT EXISTS public;
-- One row per table per pull: the dispatched statement, its receipt, and what it landed.
CREATE TABLE IF NOT EXISTS pull_log (
    run_id VARCHAR, run_started TIMESTAMPTZ, table_name VARCHAR, rows BIGINT, started TIMESTAMPTZ, finished TIMESTAMPTZ,
    status VARCHAR, http_status INTEGER, error VARCHAR, request_id VARCHAR, statement VARCHAR, receipt_body VARCHAR);

-- Serve. /sql runs any body on this process through its own quack door (quack_query is DuckDB's eval).
-- quack_serve(uri, token := ...): the token comes from the environment; unset fails closed.
SELECT listen_uri, listen_url FROM quack_serve('quack:localhost:9510', token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE ROUTE sql POST '/sql'
    AS SELECT * FROM quack_query('quack:localhost:9510', $sql, token := getenv('QUACK_TOKEN'));
-- A cold copy of audit_log takes 20-29 s, so request timeouts are raised well past quackapi's 30 s default; keep-alive
-- outlives the 10 s pull tick, so a pooled connection is not reused just as the server closes it.
FROM quackapi_serve(9511, host := '127.0.0.1', query_timeout_ms := 1800000, read_timeout_sec := 1800, write_timeout_sec := 1800,
    keep_alive_timeout_sec := 75);

-- Keep pulling: each job posts its file's CURRENT text to /sql, so an edit is live on the next tick, no restart.
-- pull.sql every 10 s (a tick copies the most stale due tables; a fresh file is full in ~3 minutes);
-- reads.sql (graph views + the two /org routes) every minute, failing harmlessly until the first tables land.
-- cron(query VARCHAR, schedule VARCHAR: 6 fields, seconds first) -> job id. quackapi_post, not http_client's
-- http_post: http_post returns status -1 at 10 s and the work behind it stops.
SELECT file, cron('SELECT quackapi_post(' || chr(39) || 'http://127.0.0.1:9511/sql' || chr(39)
    || ', json_object(' || chr(39) || 'sql' || chr(39) || ', content)).status AS status FROM read_text('
    || chr(39) || '/Users/aloksubbarao/duckdb-skills/server/replica/' || file || chr(39) || ')', schedule) AS job
FROM (SELECT 'pull.sql' AS file, '*/10 * * * * *' AS schedule UNION ALL SELECT 'reads.sql', '30 * * * * *');

-- After this no connection can SET/PRAGMA/RESET; ATTACH, CREATE and HTTP still work.
SET GLOBAL lock_configuration = true;

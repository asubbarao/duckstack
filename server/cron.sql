-- cron.sql: scheduled jobs plus the startup-source watcher. A job posts its file's CURRENT text to /sql
-- (post_file, in live.sql), so cron-only files are read fresh; the watcher restarts only when a file that
-- setup.sql .reads during startup changes.
-- cron(query VARCHAR, schedule VARCHAR: 6 fields, seconds first) -> job id

-- Derive the startup source set from setup.sql's ordered .read chain. Four levels cover the current chain
-- without treating cron-run read_text/post_file inputs, templates, probes, or other repository files as
-- startup sources. The root is always included, even though setup.sql does not .read itself. The two
-- DUCKSTACK_RELOAD_* path overrides keep scratch instances isolated from the live checkout.
CREATE OR REPLACE TABLE _reload_startup_files AS
WITH
    level0(path) AS (VALUES (coalesce(nullif(getenv('DUCKSTACK_RELOAD_SETUP'), ''),
                                      getvariable('server_dir') || '/server/setup.sql'))),
    level1(path) AS (
        SELECT DISTINCT replace(trim(replace(replace(substr(line.content, 7), chr(10), ''), chr(13), '')),
                                '/Users/aloksubbarao/duckdb-skills/server',
                                coalesce(nullif(getenv('DUCKSTACK_RELOAD_SERVER_DIR'), ''),
                                         '/Users/aloksubbarao/duckdb-skills/server'))
        FROM level0 source
        CROSS JOIN LATERAL read_lines_lateral(source.path) AS line
        WHERE starts_with(trim(line.content), '.read ')
    ),
    level2(path) AS (
        SELECT DISTINCT replace(trim(replace(replace(substr(line.content, 7), chr(10), ''), chr(13), '')),
                                '/Users/aloksubbarao/duckdb-skills/server',
                                coalesce(nullif(getenv('DUCKSTACK_RELOAD_SERVER_DIR'), ''),
                                         '/Users/aloksubbarao/duckdb-skills/server'))
        FROM level1 source
        CROSS JOIN LATERAL read_lines_lateral(source.path) AS line
        WHERE starts_with(trim(line.content), '.read ')
    ),
    level3(path) AS (
        SELECT DISTINCT replace(trim(replace(replace(substr(line.content, 7), chr(10), ''), chr(13), '')),
                                '/Users/aloksubbarao/duckdb-skills/server',
                                coalesce(nullif(getenv('DUCKSTACK_RELOAD_SERVER_DIR'), ''),
                                         '/Users/aloksubbarao/duckdb-skills/server'))
        FROM level2 source
        CROSS JOIN LATERAL read_lines_lateral(source.path) AS line
        WHERE starts_with(trim(line.content), '.read ')
    ),
    level4(path) AS (
        SELECT DISTINCT replace(trim(replace(replace(substr(line.content, 7), chr(10), ''), chr(13), '')),
                                '/Users/aloksubbarao/duckdb-skills/server',
                                coalesce(nullif(getenv('DUCKSTACK_RELOAD_SERVER_DIR'), ''),
                                         '/Users/aloksubbarao/duckdb-skills/server'))
        FROM level3 source
        CROSS JOIN LATERAL read_lines_lateral(source.path) AS line
        WHERE starts_with(trim(line.content), '.read ')
    ),
    chain(path) AS (
        SELECT path FROM level0
        UNION SELECT path FROM level1
        UNION SELECT path FROM level2
        UNION SELECT path FROM level3
        UNION SELECT path FROM level4
    ),
    existing(path) AS (
        SELECT path FROM chain WHERE path_exists(path)
    )
SELECT path, file_last_modified(path) AS startup_mtime, file_size(path) AS startup_size
FROM existing;

CREATE TABLE IF NOT EXISTS reload_watcher_receipts (
    checked_at TIMESTAMPTZ,
    changed_files JSON,
    old_mtime JSON,
    new_mtime JSON,
    action VARCHAR,
    dry_run BOOLEAN,
    restart_command VARCHAR
);

-- This body is intentionally ordered: it records the check and advances the snapshot before the final
-- self-dispatched ShellFS statement can kill this process. DUCKSTACK_RELOAD_DRY_RUN=1 records the same
-- restarted action while replacing kickstart with a no-op for scratch/CI verification.
SELECT cron($watcher$
CREATE OR REPLACE TEMP TABLE _reload_current AS
SELECT s.path,
       s.startup_mtime AS old_mtime,
       s.startup_size AS old_size,
       CASE WHEN path_exists(s.path) THEN file_last_modified(s.path) END AS new_mtime,
       CASE WHEN path_exists(s.path) THEN file_size(s.path) END AS new_size
FROM _reload_startup_files s;

CREATE OR REPLACE TEMP TABLE _reload_changed AS
SELECT *, old_mtime IS DISTINCT FROM new_mtime OR old_size IS DISTINCT FROM new_size AS changed
FROM _reload_current;

INSERT INTO reload_watcher_receipts
SELECT now() AS checked_at,
       coalesce(to_json(list({path: path, old_mtime: old_mtime, new_mtime: new_mtime,
                              old_size: old_size, new_size: new_size} ORDER BY path)
                        FILTER (WHERE changed)), '[]'::JSON) AS changed_files,
       coalesce(to_json(list({path: path, value: old_mtime} ORDER BY path)
                        FILTER (WHERE changed)), '[]'::JSON) AS old_mtime,
       coalesce(to_json(list({path: path, value: new_mtime} ORDER BY path)
                        FILTER (WHERE changed)), '[]'::JSON) AS new_mtime,
       CASE WHEN count(*) FILTER (WHERE changed) > 0 THEN 'restarted' ELSE 'skipped' END AS action,
       getenv('DUCKSTACK_RELOAD_DRY_RUN') = '1' AS dry_run,
       'nohup launchctl kickstart -k gui/$(id -u)/com.inframe.quack detached via ShellFS' AS restart_command
FROM _reload_changed;

DELETE FROM _reload_startup_files;
INSERT INTO _reload_startup_files BY NAME
SELECT path, new_mtime AS startup_mtime, new_size AS startup_size
FROM _reload_current;

CREATE OR REPLACE TEMP TABLE _reload_restart_request AS
SELECT CASE WHEN getenv('DUCKSTACK_RELOAD_DRY_RUN') = '1' THEN 'true |'
            ELSE 'nohup /bin/launchctl kickstart -k "gui/$(id -u)/com.inframe.quack" >/dev/null 2>&1 </dev/null & |'
       END AS command
FROM (SELECT count(*) FILTER (WHERE changed) AS changed_count FROM _reload_changed)
WHERE changed_count > 0;

-- read_text only accepts literals, so generate one complete nested statement per changed check and post it
-- to this server's own /sql route. This is the same-service self-dispatch boundary, and zero changed rows
-- produce zero HTTP calls.
SELECT http_post('http://127.0.0.1:' || getvariable('quackapi_port') || '/sql',
                 MAP {'Content-Type': 'application/json'},
                 json_object('sql', 'SELECT content FROM read_text(' || chr(39) ||
                     replace(command, chr(39), chr(39) || chr(39)) || chr(39) || ')')) AS restart_receipt
FROM _reload_restart_request
$watcher$, '*/30 * * * * *') AS reload_watcher_job;
SELECT cron('FROM post_file(' || chr(39) || getvariable('server_dir') || '/server/' || file || chr(39) || ')', schedule) AS job
FROM (SELECT 'live.sql' AS file, '30 * * * * *' AS schedule
      UNION ALL SELECT 'open_prs.sql', '0 7 * * * *'
      UNION ALL SELECT 'luna_ci.sql', '0 9 * * * *'
      UNION ALL SELECT 'luna_ci_done.sql', '40 * * * * *'
      UNION ALL SELECT '../readthedocs_catalog.sql', '20 * * * * *');

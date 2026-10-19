-- Every process now, the one relation the reaper (reaper.sql) reads. ps gives the numbers and the command line as
-- words. age_s comes from ps's etime ([[dd-]hh:]mm:ss), so no clock is compared. footprint_mb is top's MEM, what Activity
-- Monitor shows: it counts compressed and swapped pages, which ps's RSS does not. spawned_by names the agent behind a
-- process: 'claude' (its group leader is the zsh a Claude Bash call starts, sourcing ~/.claude/shell-snapshots), 'codex'
-- (a child of codex outside its own install and MCP servers), 'orphan' (the group leader is gone: an agent's call ended
-- and left its job running). reap marks every process of a group the reaper kills: the group's oldest process was
-- spawned by an agent, the group is 10 minutes old, and it is not an orphaned app or system helper. reap_dev_job marks a
-- process dev's shell started (a shellfs command, a nohup job) that is an hour old: it shares dev's group, started after
-- dev, so the wrapper and feeder started with dev never qualify. reap_client_job marks a command a session's own DuckDB
-- (server/client.sql) has run for over 3 minutes: one stuck shellfs command blocks every later call to that session.
-- kill_id is what the reaper kills: -pgid for a reaped group, the pid alone for the other two (they share a group
-- with a process that must live), NULL otherwise.
-- Orphaned groups whose oldest command matches one of these are apps and system helpers, never reaped.
CREATE OR REPLACE VIEW reap_exempt_prefixes AS
SELECT unnest(['%.app/Contents/%', '/System/%', '/usr/%', '/Library/%', '/opt/homebrew/Cellar/podman/%']) AS pattern;
-- Codex's own install and MCP servers: its children there are not agent work.
CREATE OR REPLACE VIEW codex_own_prefixes AS
SELECT unnest(['/Applications/ChatGPT.app/', getenv('HOME') || '/.codex/', getenv('HOME') || '/.local/bin/']) AS prefix;
CREATE OR REPLACE VIEW host_processes AS
WITH ps_words AS (
    SELECT content, list_filter(string_split(content, ' '), w -> w <> '') AS words
    FROM read_lines($cmd$ps -axww -o pid=,ppid=,pgid=,etime=,args= |$cmd$, "trim" := true)
), ps AS (   -- args is the rest of the line after etime; etime always holds a ':', so pid digits never match it
    SELECT words[1]::BIGINT AS pid, words[2]::BIGINT AS ppid, words[3]::BIGINT AS pgid, words[4] AS etime, words[5] AS exe,
           left(trim(substr(content, strpos(content, words[4]) + len(words[4]))), 2000) AS args
    FROM ps_words
), top_words AS (
    SELECT list_filter(string_split(content, ' '), w -> w <> '') AS words
    FROM read_lines($cmd$top -l 1 -stats pid,mem |$cmd$, "trim" := true)
), top AS (   -- top's process rows are a pid and its MEM; no header line starts with a number
    SELECT TRY_CAST(words[1] AS BIGINT) AS pid, words[2] AS mem FROM top_words WHERE len(words) = 2
), procs AS (
    SELECT ps.*, string_split(etime, '-') AS day_split, list_reverse(string_split(day_split[-1], ':')) AS smh,
           CASE len(day_split) WHEN 2 THEN day_split[1]::BIGINT ELSE 0 END * 86400
             + coalesce(smh[3]::BIGINT, 0) * 3600 + smh[2]::BIGINT * 60 + smh[1]::BIGINT AS age_s,
           CASE right(rtrim(mem, '+-'), 1) WHEN 'G' THEN 1024 WHEN 'M' THEN 1 WHEN 'K' THEN 1/1024 ELSE 0 END
             * TRY_CAST(rtrim(rtrim(mem, '+-'), 'BKMG') AS DOUBLE) AS footprint_mb
    FROM ps LEFT JOIN top USING (pid)
), owned AS (
    SELECT process.* EXCLUDE (day_split, smh), now() AS observed_at, leader.args AS leader_args, parent.args AS parent_args,
           CASE WHEN process.pgid <= 1 THEN NULL
                WHEN leader.pid IS NULL THEN 'orphan'
                WHEN contains(leader.args, '/.claude/shell-snapshots/') THEN 'claude'
                WHEN file_name(parent.exe) = 'codex' AND codex_own.prefix IS NULL THEN 'codex'
           END AS spawned_by
    FROM procs AS process
    LEFT JOIN procs AS leader ON leader.pid = process.pgid
    LEFT JOIN procs AS parent ON parent.pid = process.ppid
    LEFT JOIN codex_own_prefixes AS codex_own ON starts_with(process.args, codex_own.prefix)
), grouped AS (
    SELECT *, arg_max(spawned_by, age_s) OVER (PARTITION BY pgid) AS group_spawned_by,
           arg_max(args, age_s) OVER (PARTITION BY pgid) AS group_root_args, max(age_s) OVER (PARTITION BY pgid) AS group_age_s
    FROM owned
), dev_server AS (   -- dev's own duckdb; the jobs its shell starts share this group
    SELECT pgid, arg_max(pid, age_s) AS dev_pid, max(age_s) AS dev_age_s
    FROM owned WHERE file_name(exe) = 'duckdb' AND contains(args, '/.duck/db/dev.duckdb')
    GROUP BY pgid
), exempt_groups AS (
    SELECT DISTINCT process.pgid
    FROM grouped AS process JOIN reap_exempt_prefixes AS exempt_prefix ON process.group_root_args LIKE exempt_prefix.pattern
    WHERE process.group_spawned_by = 'orphan'
), marked AS (
    SELECT process.*, dev.dev_pid, dev.dev_age_s,
           coalesce(process.group_spawned_by IS NOT NULL AND process.group_age_s >= 600 AND exempt.pgid IS NULL, false) AS reap,
           coalesce(process.pid <> dev.dev_pid AND process.age_s < dev.dev_age_s AND process.age_s >= 3600, false) AS reap_dev_job,
           coalesce(contains(process.parent_args, '/server/client.sql') AND process.age_s >= 180, false) AS reap_client_job
    FROM grouped AS process
    LEFT JOIN exempt_groups AS exempt ON exempt.pgid = process.pgid
    LEFT JOIN dev_server AS dev ON dev.pgid = process.pgid
)
SELECT *, CASE WHEN reap THEN -pgid WHEN true IN (reap_dev_job, reap_client_job) THEN pid END AS kill_id
FROM marked;

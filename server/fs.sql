-- fs.files: every file under ~ (~975k), with its folder, size and times from hostfs. A question about files is a WHERE
-- on fs.files; fs.read adds each file's contents for the rows a WHERE keeps. The rest of this file keeps fs.files current.
--   fs.rules     what is left out: a name at the top of ~ (scope top) or anywhere (scope any). ~/Library/LaunchAgents stays.
--   fs.dirs      every kept folder (and each topmost excluded one) with the modified time it had when last listed.
--   fs.filelist  every file in a kept folder.
--   fs.folders   fs.dirs with depth and the rule that excludes it.
-- The refresh: fs.folders FULL OUTER JOIN the roots is the worklist, one action per row, each one self-dispatched
-- statement: list (a root not stored, or a kept folder whose time moved: record the time, insert new subfolders,
-- replace its files), walk (a folder listed but never walked: one pruned find for its folders, one for its files) or
-- gone (delete it and everything under it). A folder's time moves when an entry is added, removed or renamed in it.
-- An empty worklist posts nothing. Empty tables fill in two runs (list ~, then walk its 73 folders); a quiet run ~0.7 s.
-- Boot runs it once and cron every minute.
CREATE SCHEMA IF NOT EXISTS fs;

CREATE OR REPLACE VIEW fs.rules AS
SELECT unnest(['Library', 'Applications', 'Movies', 'Music', 'Pictures', 'Public', 'Google Drive', '.Trash']) AS name, 'top' AS scope
UNION ALL
SELECT unnest(['.git', 'node_modules', '.venv', '__pycache__', '.cache', '.mypy_cache', '.ruff_cache', '.pytest_cache',
               '.next', '.turbo', 'secrets']) AS name, 'any' AS scope;

CREATE TABLE IF NOT EXISTS fs.dirs (path VARCHAR PRIMARY KEY, modified TIMESTAMP);
CREATE TABLE IF NOT EXISTS fs.filelist (path VARCHAR PRIMARY KEY, folder VARCHAR);

CREATE OR REPLACE VIEW fs.folders AS
WITH d AS (
  SELECT path, modified, parse_dirpath(path) AS parent, file_name(path) AS name,
         string_split(path, '/')[len(string_split(getenv('HOME'), '/')) + 1:] AS rel
  FROM fs.dirs
), segments AS (
  SELECT d.path, d.rel, s.seg, s.idx FROM d CROSS JOIN UNNEST(d.rel) WITH ORDINALITY AS s(seg, idx)
), hits AS (
  SELECT s.path, s.idx FROM segments s JOIN fs.rules r ON r.name = s.seg AND r.scope = 'any'
  UNION ALL
  SELECT s.path, s.idx FROM segments s JOIN fs.rules r ON r.name = s.seg AND r.scope = 'top'
  WHERE s.idx = 1 AND s.rel[1:2] IS DISTINCT FROM ['Library', 'LaunchAgents']
), cut AS (
  SELECT path, min(idx) AS cut FROM hits GROUP BY path
)
SELECT d.path, d.parent, d.name, len(d.rel) AS depth, d.modified, c.cut IS NOT NULL AS excluded, d.rel[c.cut] AS reason
FROM d LEFT JOIN cut c USING (path);

CREATE OR REPLACE VIEW fs.files AS
SELECT path, folder, file_name(path) AS name, parse_filename(path, true) AS stem, file_extension(path) AS ext,
       file_size(path) AS bytes, file_last_modified(path) AS modified
FROM fs.filelist;

CREATE OR REPLACE VIEW fs.read AS
SELECT f.*, selfdispatch(tera_render(CASE
         WHEN f.ext = '.parquet' THEN $t$SELECT to_json(t) AS row FROM read_parquet($p${{ path }}$p$) t$t$
         WHEN f.ext IN ('.json', '.jsonl', '.ndjson') THEN $t$SELECT to_json(t) AS row FROM read_json($p${{ path }}$p$) t$t$
         WHEN f.ext IN ('.csv', '.tsv') THEN $t$SELECT to_json(t) AS row FROM read_csv($p${{ path }}$p$) t$t$
         ELSE $t$SELECT TRY(decode(content)) AS content FROM read_blob($p${{ path }}$p$)$t$
       END, json_object('path', f.path), autoescape := false)).body AS body
FROM fs.files f;

WITH program AS (
    SELECT $refresh$
WITH roots AS (
  -- A root that does not exist (~/Library/LaunchAgents off a Mac, or CI's empty HOME) has nothing to list.
  SELECT path FROM (SELECT unnest([getenv('HOME'), getenv('HOME') || '/Library/LaunchAgents']) AS path) t WHERE path_exists(path)
), worklist AS (
  SELECT path, f.modified, 'any' AS scope,
         CASE WHEN f.depth IS NULL THEN 'list'
              WHEN NOT path_exists(path) THEN 'gone'
              WHEN f.excluded THEN NULL
              WHEN f.modified = '-infinity'::TIMESTAMP THEN 'walk'
              WHEN file_last_modified(path) > f.modified THEN 'list' END AS action
  FROM fs.folders f FULL OUTER JOIN roots r USING (path)
), pruned AS (   -- a walk prunes the names excluded at any depth
  SELECT scope, list(name) AS names FROM fs.rules GROUP BY scope
), work AS (
  SELECT w.path, w.action, file_last_modified(w.path) AS now_modified, p.names
  FROM worklist w JOIN pruned p USING (scope)
  WHERE w.action IS NOT NULL
), statements AS (
  SELECT action, tera_render(CASE action
    WHEN 'gone' THEN $t$DELETE FROM fs.dirs WHERE starts_with(path || '/', $p${{ path }}/$p$);
DELETE FROM fs.filelist WHERE starts_with(path, $p${{ path }}/$p$);$t$
    WHEN 'list' THEN $t$INSERT OR REPLACE INTO fs.dirs SELECT $p${{ path }}$p$ AS path, TRY_CAST('{{ now_modified }}' AS TIMESTAMP) AS modified;
INSERT OR IGNORE INTO fs.dirs SELECT path, '-infinity'::TIMESTAMP AS modified FROM ls($p${{ path }}$p$) WHERE is_dir(path);
DELETE FROM fs.filelist WHERE folder = $p${{ path }}$p$;
INSERT OR IGNORE INTO fs.filelist SELECT path, $p${{ path }}$p$ AS folder FROM ls($p${{ path }}$p$) WHERE is_file(path);$t$
    WHEN 'walk' THEN $t$INSERT OR REPLACE INTO fs.dirs SELECT path, file_last_modified(path) AS modified
FROM (SELECT rtrim(content, E'\n') AS path FROM read_lines($c$find '{{ path | replace(from="'", to="'\''") }}' \( -name {{ names | join(sep=" -o -name ") }} \) -prune -print -o -type d -print 2>/dev/null |$c$));
INSERT OR IGNORE INTO fs.filelist SELECT path, parse_dirpath(path) AS folder
FROM (SELECT rtrim(content, E'\n') AS path FROM read_lines($c$find '{{ path | replace(from="'", to="'\''") }}' \( -name {{ names | join(sep=" -o -name ") }} \) -prune -o -type f -print 2>/dev/null |$c$));$t$
  END, w::JSON, autoescape := false) AS sql
  FROM work w
), posted AS (
  SELECT array_agg({action: action, receipt: selfdispatch(sql)}) AS receipts FROM statements
)
SELECT r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r);
$refresh$ AS sql
), posted AS (
    SELECT sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY sql
)
SELECT cron(sql, '30 * * * * *') AS job, r.status FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

-- fs: every file under ~, live. A question about any file is a WHERE clause; nothing is cached.
--   fs.files    one row per file. rg walks in parallel (2.1 s for ~965k files; find -type d takes 97 s);
--               roots and pruned names are arrays rendered into the command by tera.
--   fs.folders  one row per folder that holds a file: file count, bytes, newest file.
--   fs.read     each file read by a self-dispatched reader chosen by extension; only the rows the WHERE keeps are read.
CREATE SCHEMA IF NOT EXISTS fs;

CREATE OR REPLACE VIEW fs.files AS
WITH walk AS (
  SELECT getenv('HOME') AS home,
         ['', '/Library/LaunchAgents'] AS roots,
         ['.git', '.venv', 'node_modules', '__pycache__', '.cache', '.mypy_cache', '.ruff_cache', '.pytest_cache',
          '.next', '.turbo', 'Library', '.Trash', 'secrets'] AS prune
), cmd AS (
  SELECT tera_render($t$rg --files --hidden --no-ignore --no-messages -g '!{{ "{" }}{{ prune | join(sep=",") }}{{ "}" }}'{% for r in roots %} {{ home }}{{ r }}{% endfor %}; true |$t$,
                     to_json(walk), autoescape := false) AS command
  FROM walk
)
SELECT rtrim(l.content, E'\n') AS path, parse_dirpath(path) AS folder, file_name(path) AS name, file_extension(path) AS ext,
       file_size(path) AS bytes, file_last_modified(path) AS modified
FROM cmd CROSS JOIN LATERAL read_lines_lateral(cmd.command) l;

CREATE OR REPLACE VIEW fs.folders AS
SELECT folder, count() AS files, sum(bytes) AS bytes, max(modified) AS modified, max_by(path, modified) AS newest
FROM fs.files GROUP BY folder;

CREATE OR REPLACE VIEW fs.read AS
SELECT f.*, http_post('http://127.0.0.1:9495/sql', MAP {'content-type': 'application/json'},
       json_object('sql', tera_render(CASE
         WHEN f.ext = '.parquet' THEN $t$SELECT to_json(t) AS row FROM read_parquet($p${{ path }}$p$) t$t$
         WHEN f.ext IN ('.json', '.jsonl', '.ndjson') THEN $t$SELECT to_json(t) AS row FROM read_json($p${{ path }}$p$) t$t$
         WHEN f.ext IN ('.csv', '.tsv') THEN $t$SELECT to_json(t) AS row FROM read_csv($p${{ path }}$p$) t$t$
         ELSE $t$SELECT TRY(decode(content)) AS content FROM read_blob($p${{ path }}$p$)$t$
       END, json_object('path', f.path), autoescape := false)))->>'body' AS body
FROM fs.files f;

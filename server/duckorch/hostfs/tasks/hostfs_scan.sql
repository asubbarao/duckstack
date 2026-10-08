-- @task name=hostfs_scan
-- @description Every folder and file under /Users/aloksubbarao/inframe, one ls wave per depth, pruned by name before descending.
-- @inputs hostfs.policy
-- @outputs hostfs.scan
-- ls binds a literal, so each frontier folder's ls is self-dispatched to a quackapi route this
-- process serves; a hidden or skip_dir folder never reaches the frontier. The columns are
-- dev's main.hostfs_scan plus depth.
CREATE OR REPLACE TABLE hostfs.scan (path VARCHAR, depth INTEGER);
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT '/Users/aloksubbarao/inframe' AS path),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 1 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT path FROM hostfs.scan WHERE depth = 1 AND is_dir(path)),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 2 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT path FROM hostfs.scan WHERE depth = 2 AND is_dir(path)),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 3 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT path FROM hostfs.scan WHERE depth = 3 AND is_dir(path)),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 4 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT path FROM hostfs.scan WHERE depth = 4 AND is_dir(path)),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 5 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT path FROM hostfs.scan WHERE depth = 5 AND is_dir(path)),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 6 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT path FROM hostfs.scan WHERE depth = 6 AND is_dir(path)),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 7 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT path FROM hostfs.scan WHERE depth = 7 AND is_dir(path)),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 8 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT path FROM hostfs.scan WHERE depth = 8 AND is_dir(path)),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 9 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT path FROM hostfs.scan WHERE depth = 9 AND is_dir(path)),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 10 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT path FROM hostfs.scan WHERE depth = 10 AND is_dir(path)),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 11 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT path FROM hostfs.scan WHERE depth = 11 AND is_dir(path)),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 12 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT path FROM hostfs.scan WHERE depth = 12 AND is_dir(path)),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 13 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT path FROM hostfs.scan WHERE depth = 13 AND is_dir(path)),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 14 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
INSERT INTO hostfs.scan BY NAME
WITH frontier AS (SELECT path FROM hostfs.scan WHERE depth = 14 AND is_dir(path)),
fired AS (SELECT array_agg(http_post_form('http://127.0.0.1:19504/q', MAP{},
    MAP{'q': printf('SELECT path FROM ls(%s)', chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39))})) AS responses FROM frontier),
listed AS (SELECT row.path AS path FROM fired, UNNEST(responses) AS u(r),
    UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR"}]')) AS s(row) WHERE r.status = 200)
SELECT path, 15 AS depth FROM listed
WHERE NOT starts_with(file_name(path), '.')
  AND file_name(path) NOT IN (SELECT name FROM hostfs.policy WHERE kind = 'skip_dir');
CREATE OR REPLACE TABLE hostfs.scan AS
SELECT path, file_name(path) AS file_name, file_extension(path) AS file_extension,
  is_dir(path) AS is_dir, is_file(path) AS is_file, file_size(path) AS file_size,
  hsize(file_size(path)) AS hsize, file_last_modified(path) AS file_last_modified, depth
FROM hostfs.scan;

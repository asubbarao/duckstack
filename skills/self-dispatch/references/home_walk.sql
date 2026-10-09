-- Bounded home traversal: home -> duckdb-skills -> server.
-- Edit the folder allow-lists before expanding scope. Each post/entries pair is one level.
-- Excluded entries remain visible; only eligible directories are dispatched.
-- Every receipt and generated statement is retained. Empty/error listings keep a NULL-path row.
WITH home AS (
    SELECT 1 AS depth, getenv('HOME') AS folder, path, absolute_path(path) AS absolute_path,
        file_name(path) AS file_name, file_extension(path) AS file_extension,
        is_dir(path) AS is_dir, is_file(path) AS is_file,
        path_exists(path) AS path_exists, path_type(path) AS path_type,
        path_split(path) AS path_parts, file_size(path) AS file_size,
        hsize(file_size) AS hsize, file_last_modified(path) AS file_last_modified,
        pwd() AS working_directory, path_separator() AS path_separator,
        list_has_any(parse_path(absolute_path), ['node_modules', 'dump', '__pycache__', 'venv', 'dist', 'build']) AS ignored,
        list_contains(list_transform(parse_path(absolute_path), part -> starts_with(part, '.')), true) AS hidden,
        list_contains([ignored, hidden], true) AS excluded
    FROM ls(getenv('HOME'))
), post_project AS (
    SELECT path AS folder,
        printf($ls$SELECT coalesce(array_agg(path ORDER BY path), []) AS paths FROM ls('%s') LIMIT 4$ls$,
               replace(path, chr(39), chr(39) || chr(39))) AS statement,
        http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type':'application/json'},
                  json_object('sql', statement)) AS receipt
    FROM home
    WHERE is_dir AND NOT excluded
      AND file_name IN ('duckdb-skills')
), project_entries AS (
    SELECT 2 AS depth, folder, statement, receipt,
        try((receipt->>'status')::INTEGER) AS status,
        CASE WHEN status = 200
             THEN try(from_json(receipt->>'body', '[{"paths":["VARCHAR"]}]')[1].paths) END AS paths,
        CASE WHEN status IS DISTINCT FROM 200 THEN receipt->>'body'
             WHEN paths IS NULL THEN 'Unrecognized listing response' END AS error,
        CASE WHEN status = 200 AND paths IS NOT NULL THEN len(paths) = 0 END AS empty,
        unnest(CASE WHEN len(paths) > 0 THEN paths ELSE [NULL] END) AS path,
        absolute_path(path) AS absolute_path,
        file_name(path) AS file_name, file_extension(path) AS file_extension,
        is_dir(path) AS is_dir, is_file(path) AS is_file,
        path_exists(path) AS path_exists, path_type(path) AS path_type,
        path_split(path) AS path_parts, file_size(path) AS file_size,
        hsize(file_size) AS hsize, file_last_modified(path) AS file_last_modified,
        pwd() AS working_directory, path_separator() AS path_separator,
        list_has_any(parse_path(absolute_path), ['node_modules', 'dump', '__pycache__', 'venv', 'dist', 'build']) AS ignored,
        list_contains(list_transform(parse_path(absolute_path), part -> starts_with(part, '.')), true) AS hidden,
        list_contains([ignored, hidden], true) AS excluded
    FROM post_project
), post_subfolders AS (
    SELECT path AS folder,
        printf($ls$SELECT coalesce(array_agg(path ORDER BY path), []) AS paths FROM ls('%s') LIMIT 4$ls$,
               replace(path, chr(39), chr(39) || chr(39))) AS statement,
        http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type':'application/json'},
                  json_object('sql', statement)) AS receipt
    FROM (SELECT path, file_name, is_dir, excluded FROM project_entries)
    WHERE is_dir AND NOT excluded
      AND file_name IN ('server')
), subfolder_entries AS (
    SELECT 3 AS depth, folder, statement, receipt,
        try((receipt->>'status')::INTEGER) AS status,
        CASE WHEN status = 200
             THEN try(from_json(receipt->>'body', '[{"paths":["VARCHAR"]}]')[1].paths) END AS paths,
        CASE WHEN status IS DISTINCT FROM 200 THEN receipt->>'body'
             WHEN paths IS NULL THEN 'Unrecognized listing response' END AS error,
        CASE WHEN status = 200 AND paths IS NOT NULL THEN len(paths) = 0 END AS empty,
        unnest(CASE WHEN len(paths) > 0 THEN paths ELSE [NULL] END) AS path,
        absolute_path(path) AS absolute_path,
        file_name(path) AS file_name, file_extension(path) AS file_extension,
        is_dir(path) AS is_dir, is_file(path) AS is_file,
        path_exists(path) AS path_exists, path_type(path) AS path_type,
        path_split(path) AS path_parts, file_size(path) AS file_size,
        hsize(file_size) AS hsize, file_last_modified(path) AS file_last_modified,
        pwd() AS working_directory, path_separator() AS path_separator,
        list_has_any(parse_path(absolute_path), ['node_modules', 'dump', '__pycache__', 'venv', 'dist', 'build']) AS ignored,
        list_contains(list_transform(parse_path(absolute_path), part -> starts_with(part, '.')), true) AS hidden,
        list_contains([ignored, hidden], true) AS excluded
    FROM post_subfolders
)
SELECT * FROM home
UNION ALL BY NAME
SELECT * EXCLUDE (paths) FROM project_entries
UNION ALL BY NAME
SELECT * EXCLUDE (paths) FROM subfolder_entries
;

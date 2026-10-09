WITH metadata AS (
    SELECT getenv('HOME') AS root, path, absolute_path(path) AS abspath,
           path_split(abspath) AS abs_parts,
           path_split(absolute_path(root)) AS root_parts,
           CASE WHEN abs_parts[:len(root_parts)] = root_parts
                THEN abs_parts[len(root_parts) + 1:] END AS parts,
           array_to_string(parts, path_separator()) AS relpath,
           file_name(path) AS name, file_extension(path) AS extension,
           is_dir(path) AS is_dir, is_file(path) AS is_file,
           file_size(path) AS bytes, hsize(file_size(path)) AS human_size,
           file_last_modified(path) AS last_modified,
           path_exists(path) AS path_exists, path_type(path) AS type,
           pwd() AS working_directory,
           path_separator() AS separator, hostfs(path) AS hostfs
    FROM ls(getenv('HOME'))
), statements AS (
    SELECT *, chr(39) AS quote,
           replace(path, quote, quote || quote) AS quoted_path,
           'SELECT coalesce(array_agg(path), []) AS paths FROM ls('
               || quote || quoted_path || quote || ', true)' AS q
    FROM metadata
), requests AS (
    SELECT * EXCLUDE (quote, quoted_path), MAP {'sql': q} AS form
    FROM statements
), dispatched AS (
    SELECT *, CASE WHEN is_dir THEN
        http_post_form('http://127.0.0.1:9495/sql', MAP {}, form)
    END AS receipt
    FROM requests
), packed AS (
    SELECT array_agg(dispatched) AS receipts FROM dispatched
), results AS (
    SELECT item.*, try_cast(item.receipt ->> '$.status' AS INTEGER) AS status,
           json_extract_string(try_cast(item.receipt ->> '$.body' AS JSON),
                               '$[0].paths[*]') AS children,
           list_filter(children, child -> is_file(child)) AS files,
           list_filter(children, child -> is_dir(child)) AS folders,
           CASE WHEN item.is_dir THEN
               CASE WHEN status IS DISTINCT FROM 200 THEN item.receipt ->> '$.body'
                    WHEN children IS NULL THEN 'Unrecognized listing response' END
           END AS error
    FROM packed CROSS JOIN UNNEST(receipts) AS r(item)
)
SELECT * FROM results
-- ORDER BY is_dir DESC,
--          CASE WHEN parts[-1][:1] = '.' THEN 1 ELSE 0 END,
--          lower(parts[-1]), abspath
;

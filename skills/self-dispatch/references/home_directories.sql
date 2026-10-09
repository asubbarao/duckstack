-- Four LS iterations from HOME. Directory arrays feed each next self-dispatch.
-- Includes hidden directories; no file contents are read. Empty/error receipts remain rows.
WITH walk AS (
    SELECT list_reduce(
        list_transform(range(1, 5), d -> struct_pack(
            depth := d::INTEGER, paths := []::VARCHAR[], receipts := []::STRUCT(depth INTEGER, folder VARCHAR, statement VARCHAR, receipt JSON)[]
        )),
        (state, step) -> list_transform(
            [list_transform(state.paths, folder -> list_transform(
                [printf($ls$SELECT coalesce(array_agg(path ORDER BY path), []::VARCHAR[]) AS paths FROM ls('%s') WHERE is_dir(path) LIMIT 4$ls$,
                        replace(folder, chr(39), chr(39) || chr(39)))],
                statement -> struct_pack(
                    depth := step.depth, folder := folder, statement := statement,
                    receipt := http_post('http://127.0.0.1:9495/sql',
                        MAP {'Content-Type': 'application/json'},
                        json_object('sql', statement))
                )
            )[1])],
            batch -> struct_pack(
                depth := step.depth,
                paths := flatten(list_transform(batch, item ->
                    coalesce(try(from_json(item.receipt ->> '$.body',
                        '[{"paths":["VARCHAR"]}]')[1].paths), []::VARCHAR[])
                )),
                receipts := list_concat(state.receipts, batch)
            )
        )[1],
        struct_pack(depth := 0, paths := [getenv('HOME')], receipts := []::STRUCT(depth INTEGER, folder VARCHAR, statement VARCHAR, receipt JSON)[])
    ) AS result
), listings AS (
    SELECT listing.*
    FROM walk CROSS JOIN UNNEST(result.receipts) AS r(listing)
), directories AS (
    SELECT depth, folder, statement, receipt,
           try_cast(receipt ->> '$.status' AS INTEGER) AS status,
           try(from_json(receipt ->> '$.body', '[{"paths":["VARCHAR"]}]')[1].paths) AS paths,
           CASE WHEN status IS DISTINCT FROM 200 THEN receipt ->> '$.body'
                WHEN paths IS NULL THEN 'Unrecognized listing response' END AS error,
           unnest(CASE WHEN len(paths) > 0 THEN paths ELSE [NULL]::VARCHAR[] END) AS path
    FROM listings
)
SELECT depth, folder, path, absolute_path(path) AS abspath,
       file_name(path) AS name, file_extension(path) AS extension,
       file_last_modified(path) AS last_modified, file_size(path) AS bytes,
       hsize(file_size(path)) AS human_size,
       is_dir(path) AS is_directory, is_file(path) AS is_regular_file,
       path_exists(path) AS exists, path_type(path) AS type,
       path_split(path) AS parts, pwd() AS working_directory,
       path_separator() AS separator, statement, receipt, status, error
FROM directories;

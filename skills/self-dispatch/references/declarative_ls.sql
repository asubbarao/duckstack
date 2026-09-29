-- Walk a tree and read every file, by self-dispatch on the dev server (hostfs_info is in server/live.sql).
-- Each stage builds its statement from parts (parts and text both kept), posts it to /sql, and keeps the receipt.
-- Folders are pruned in the WHERE before their ls is posted, so a pruned folder is never read.
-- ls([path]) -> path; hostfs_info(path) -> STRUCT of hostfs scalars; read_markdown(path); read_text(path)
-- http_post(url, headers MAP, body JSON [, params MAP]) -> JSON {status, reason, body}. Dispatched SELECTs carry a LIMIT (/sql returns 20 otherwise).
WITH top AS (SELECT unnest(hostfs_info(path)), * FROM ls('/Users/aloksubbarao/duckdb-skills/skills')),
listed AS (
    SELECT *, ['FROM ls(', chr(39) || path || chr(39), ')', 'LIMIT 100000'] AS ls_parts, array_to_string(ls_parts, ' ') AS ls_sql,
        http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', ls_sql)) AS ls_receipt
    FROM top WHERE is_dir AND NOT starts_with(file_name, '.')
),
files AS (
    SELECT unnest(hostfs_info(entry.path)), entry.path, listed.path AS folder, ls_sql, ls_receipt ->> '$.status' AS ls_status
    FROM listed, unnest(from_json(ls_receipt ->> '$.body', '[{"path":"VARCHAR"}]')) AS e(entry)
)
SELECT *, CASE WHEN file_extension = '.md' THEN 'read_markdown(' ELSE 'read_text(' END AS reader,
    ['FROM', reader || chr(39) || path || chr(39) || ')', 'LIMIT 100000'] AS read_parts, array_to_string(read_parts, ' ') AS read_sql,
    http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', read_sql)) AS read_receipt
FROM files WHERE is_file

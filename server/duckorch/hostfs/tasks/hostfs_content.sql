-- @task name=hostfs_content
-- @description The text of every scanned file up to max_content_bytes; binary files keep NULL text.
-- @inputs hostfs.scan, hostfs.policy
-- @outputs hostfs.content
-- read_blob binds a literal list, so files go out in self-dispatched reads bounded by 512 KB
-- of content and 3,000 characters of paths (quackapi answers 413 past about 8 KB of
-- form-encoded request, and encoding triples every '/'), and each response stays its own
-- row: gathering them all into one array first runs out of memory on the JSON.
-- try(decode(...)) leaves NULL where the bytes are not UTF-8 text.
CREATE OR REPLACE TABLE hostfs.content AS
WITH cap AS (SELECT name::BIGINT AS bytes FROM hostfs.policy WHERE kind = 'max_content_bytes'),
wanted AS (
  SELECT path, file_size,
    parse_dirpath(path)
      || '#' || (sum(file_size) OVER (PARTITION BY parse_dirpath(path) ORDER BY path) // 524288)
      || '.' || (sum(strlen(path) + 4) OVER (PARTITION BY parse_dirpath(path) ORDER BY path) // 3000)
      AS batch
  FROM hostfs.scan, cap
  WHERE is_file AND file_size BETWEEN 1 AND cap.bytes),
batches AS (
  SELECT batch, printf('SELECT filename AS path, try(decode(content)) AS text FROM read_blob(%s)',
    '[' || string_agg(chr(39) || replace(path, chr(39), chr(39) || chr(39)) || chr(39), ', ') || ']') AS q
  FROM wanted GROUP BY batch),
fired AS (SELECT batch, http_post_form('http://127.0.0.1:19504/q', MAP{}, MAP{'q': q}) AS r FROM batches),
read AS (
  SELECT row.path AS path, row.text AS text
  FROM fired, UNNEST(from_json(r.body ->> '$', '[{"path":"VARCHAR","text":"VARCHAR"}]')) AS s(row)
  WHERE r.status = 200)
SELECT s.path, s.file_size, s.file_last_modified, r.text
FROM hostfs.scan AS s JOIN read AS r USING (path);

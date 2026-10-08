---
name: hostfs-ls
description: A directory as rows with every hostfs path scalar — FROM ls() with file_name, file_extension, is_dir, is_file, path_type, path_exists, absolute_path, path_split, file_size, hsize, file_last_modified. Use to list files, walk a tree level by level (self-dispatch), or pick a reader per file.
allowed-tools: mcp__dev__query_with_limit, mcp__dev__query_no_limit
---

# hostfs_ls

```sql
-- ls([path VARCHAR [, BOOLEAN]]) -> path (one directory, not recursive)
SELECT file_name(path) AS file_name, file_extension(path) AS file_extension, is_dir(path) AS is_dir,
    is_file(path) AS is_file, path_type(path) AS path_type, path_exists(path) AS path_exists,
    absolute_path(path) AS absolute_path, path_split(path) AS path_parts, file_size(path) AS file_size,
    hsize(file_size(path)) AS hsize, file_last_modified(path) AS file_last_modified, *
FROM ls('/some/dir')
```

That is the whole idea. On the dev server (from `~/duckdb-skills/server/setup.sql`):

- `hostfs_info(path)` — the same scalars as one struct; `SELECT unnest(hostfs_info(path)), * FROM ls('/dir')`.
- view `hostfs_ls` — `ls()` of the server's working directory with every scalar.
- view `hostfs_ls_2` — one level down: each non-dot folder of `hostfs_ls` self-dispatched as `FROM ls('<dir>')`.

## Deeper levels and reading the files

`ls` takes a literal, so each further level is a self-dispatch: build `FROM ls('<dir>')` per kept folder,
`http_post` it to `http://127.0.0.1:9495/sql`, unnest the receipt, apply `hostfs_info` to the returned paths.
Prune (dot folders, `node_modules`, `.venv`) in the WHERE **before** dispatching, so a pruned folder is never
listed. At the files, a `CASE WHEN file_extension = '.md' THEN 'FROM read_markdown(…)'` picks the reader and
that is dispatched too. Worked example, verified 2026-09-28 (skills → each skill folder → every SKILL.md read):
`~/duckdb-skills/skills/self-dispatch/references/declarative_ls.sql`.

Every dispatched SELECT carries an explicit `LIMIT` (the `/sql` route returns 20 rows otherwise). Never
`lsr()` a tree and filter afterwards: it walks everything first.

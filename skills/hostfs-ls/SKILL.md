---
name: hostfs-ls
description: List directories through the hostfs_ls view, filtering folder before self-dispatch; use native ls for an arbitrary literal path.
allowed-tools: mcp__dev__query_with_limit, mcp__dev__query_no_limit
---

# Directories as a view

```sql
SELECT folder, path, is_dir, file_size, status, error
FROM hostfs_ls
WHERE folder = getenv('HOME') || '/duckdb-skills'
ORDER BY path;
```

The view discovers home and its immediate visible subdirectories on each query.
Deeper folders are explicit input rows, not a recursive scan:

```sql
MERGE INTO lake.main.hostfs_folders AS target
USING (SELECT getenv('HOME') || '/duckdb-skills/server' AS folder) AS source
ON target.folder=source.folder
WHEN NOT MATCHED THEN INSERT BY NAME;

SELECT * FROM hostfs_ls
WHERE folder = getenv('HOME') || '/duckdb-skills/server';
```

Use absolute paths: HostFS does not expand `~`. Folder registration stores only paths;
entries are listed afresh. Registrations live in the local DuckLake; `hostfs_folders`
is a compatibility view and survives rebuilding dev from the attached lake.
A WHERE value not in the folder inputs returns no rows.
An unfiltered query dispatches every input folder; an outer LIMIT is not a dispatch budget.

Each selected folder produces one JSON POST to the existing dev service at
`http://127.0.0.1:9495/sql`. The statement quotes apostrophes and aggregates all entries
inside the response, avoiding the endpoint's row cap. Hidden entries and resolved
hidden/ignored paths are excluded before metadata is returned. Ignored components:
`node_modules`, `dump`, `__pycache__`, `venv`, `dist`, `build`.

Every row retains folder, generated statement, raw receipt, status and error.
An empty directory retains one row with NULL path and empty=true.
A failed listing retains one row with NULL path and its error.
Filter `path IS NOT NULL` only when those diagnostic rows are unwanted.

## Filter placement matters

Verified on dev 2026-10-08: projection `unnest(entries)` lets an outer folder
filter reach the input rows before the HTTP projection. A two-directory probe with
a sequence increment in each dispatched statement measured exactly one call.
The equivalent correlated CROSS JOIN UNNEST shape dispatched both directories.
Keep the projection shape and recheck this property after optimizer or view changes.

Also verified: 35 entries survive the endpoint row cap; an apostrophe in a folder
name is quoted correctly; empty and missing directories remain distinguishable.

The MCP hostfs_ls tool calls native `ls($path)` directly for arbitrary paths.
Neither that tool nor the view uses a directory-listing macro.
The older `hostfs_info(path)` metadata helper remains for existing
`self-dispatch/references/declarative_ls.sql` callers.

For a one-off directory, native SQL is sufficient:

```sql
SELECT path, is_dir(path) AS is_dir, file_size(path) AS bytes
FROM ls('/some/directory');
```

## Bounded traversal and ScalarFS

[home_walk.sql](../self-dispatch/references/home_walk.sql) starts at home and uses
one post/entries CTE pair per subsequent level. It descends into duckdb-skills,
then server; edit each allow-list to change scope. Excluded entries remain visible
but are never used for the next dispatch. Every level projects all 13 documented
HostFS metadata functions, including pwd(), path_separator(), and HostFS's built-in
path_split() helper. No custom listing macro is required.

ScalarFS passes selected files to a native reader in one complete SQL body:

```sql
COPY (
    SELECT path FROM hostfs_ls
    WHERE folder = getenv('HOME') || '/duckdb-skills'
      AND is_file AND file_name IN ('README.md', 'LICENSE')
) TO 'variable:chosen_files' (FORMAT variable, LIST scalar);

SELECT filename, content FROM read_text('pathvariable:chosen_files');
```

Variables belong to this connection. ScalarFS supplies paths; self-dispatch performs
the traversal. Use a nonempty selection for the reader. In successive post CTEs,
project only the needed input columns: an inherited statement column otherwise
takes precedence over a new same-query statement alias.

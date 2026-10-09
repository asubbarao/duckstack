---
name: hostfs-ls
description: List and size directories on dev with the hostfs extension (ls, lsr, is_dir, file_size, file_name); prune by name before descending; self-dispatch for a folder column.
---

# Directories with hostfs

hostfs is loaded on dev. Absolute paths only; it does not expand `~`.

```sql
SELECT path, file_name(path) AS name, is_dir(path) AS is_dir, file_size(path) AS bytes
FROM ls('/Users/aloksubbarao/duckdb-skills')
ORDER BY is_dir DESC, name;
```

`lsr(path)` walks the whole tree, including `.git` and `node_modules`; use it only on a folder
already known to be small. Otherwise list one level, prune in the WHERE
(`NOT starts_with(name, '.') AND name NOT IN ('node_modules', '__pycache__', 'venv', 'dist', 'build')`),
and list the surviving folders in the next stage. `ls` takes a literal, so the next stage is
self-dispatch: see `/duckstack:self-dispatch`, whose molecule is exactly this walk.

Measure before reading: `file_size` summed by folder tells you what a `read_text` glob would pull in.

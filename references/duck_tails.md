# duck_tails — reference, reconciled against the shipped build

Docs read: https://duck-tails.readthedocs.io/en/latest/ (repo at docs commit 1223e5d, 2026-09-16) —
index, quickstart, installation, guide/git-uris, guide/lateral-joins, guide/reading-files,
guide/lfs, reference/* (git_log, git_tree, git_read, git_uri, git_branches, git_tags, git_parents,
git_blame, diff), llmtxt.md, plus `src/` for the two functions the docs never mention.
Installed on this machine: **742af7b** (`~/.duckdb/extensions/v1.5.5/osx_arm64/duck_tails`). Where
the shipped build and the docs disagree, the build is marked **[742af7b]**. Verified 2026-09-17.

## The URI

`git://[repo]/[file]@[ref]`. `git://README.md@HEAD` (repo discovered by walking up from cwd),
`git://.@HEAD` (repo root, no file), `git://../sibling@main`, `git:///abs/path/repo/src/x.py@v1.0`.
Refs: branch, tag, full/short SHA (≥4 chars), `HEAD~2`, `HEAD^2`, `main@{1.day.ago}`. After
discovery, `..` inside the *file* part is rejected. `git_uri(repo, file, ref)` builds one
(`git_uri('.', '', 'HEAD')` → `git://.@HEAD`). Every DuckDB reader accepts the URI:
`read_csv('git://data.csv@HEAD~1')`, `read_text('git://src/x.cpp@main')`, `read_parquet`, `read_json`.
LFS pointers are resolved from `.git/lfs/objects/`; an un-pulled object raises.

## Table functions (positional forms that bind on 742af7b)

| Function | Signatures | Columns |
|---|---|---|
| `git_log()` / `git_log(repo_path)` / `git_log('git://repo@ref')` | walks from ref, newest first; the docs' `git_log('.', 'develop')` two-arg form exists as `git_log(col0, repo_path :=)` | `repo_path, commit_hash, author_name, author_email, committer_name, committer_email, author_date, commit_date, message, parent_count, tree_hash` |
| `git_tree(rev)` / `git_tree(repo, rev)` / `git_tree(uri)` | `kind` is `file` \| `directory` (docs elsewhere say `blob`) | `git_uri, repo_path, commit_hash, tree_hash, file_path, file_ext (".py"), ref, blob_hash, commit_date, mode, size_bytes, kind, is_text, encoding` |
| `git_read(uri [, max_bytes, decode_base64, transcode, filters])` | positional only; **no `(path, ref)` form** — build the URI | 16 cols incl. `text` (text files) / `blob` (binary), `truncated`, `size_bytes` (always the whole file) |
| `git_branches([repo])`, `git_tags([repo])` | | `branch_name, commit_hash, is_current, is_remote` / `tag_name, commit_hash, tag_hash, tagger_name, tagger_date, message, is_annotated` |
| `git_parents(rev)` / `(repo, rev)` / `(uri)`, named `all_refs` | | `repo_path, commit_hash, parent_hash, parent_index` |
| `git_blame(file_or_uri, revision := 'HEAD', repo_path := '.', min_line, max_line, ignore_whitespace, use_mailmap, first_parent)` | one row per line; `git_blame_hunks(...)` one row per hunk (`start_line, line_count, orig_start_line`) | `repo_path, file_path, file_ext, revision, line_number, line_content, commit_hash, author_name, author_email, author_date, orig_commit_hash, orig_path, orig_line_number, boundary` |
| **`git_diff_tree(repo_or_path [, from_ref [, to_ref]], path :=, untracked :=)`** — undocumented | **first positional is a repo/dir path, never a ref.** `git_diff_tree('.', 'main', 'pr25')` = files changed main→pr25. With one ref, the diff is *ref vs working directory + index*. `git_diff_tree('81673e6','pr25')` therefore silently diffs `pr25` against the checkout. | `repo_path, file_path, file_ext, status (added\|deleted\|modified\|renamed\|copied\|typechange), old_path` |
| **`git_status([repo], untracked :=, ignored :=, path :=)`** — undocumented | working-tree status | `repo_path, file_path, file_ext, status, status_flags, staged, unstaged, old_path` |

Every one has an `_each` twin that only binds inside `LATERAL` with a column argument:
`FROM git_tree('HEAD') t, LATERAL git_read_each(t.git_uri) r`,
`FROM git_log() l, LATERAL git_tree_each('.', l.commit_hash) t`,
`LATERAL git_blame_each(file, l.commit_hash)`, `LATERAL git_diff_tree_each(...)`, `git_status_each`.
Named parameters do **not** bind inside a LATERAL on 1.5.5 (`min_line := 1` is parsed as a column) —
use the positional forms there. `LEFT JOIN LATERAL … ON true` keeps commits where the file is absent.

## Diff functions — the part that bit us

`text_diff(old, new)` (alias `diff_text`) is a **positional line walk, not Myers/LCS** (source:
"Simple diff algorithm - Myers algorithm would be better"). One inserted line makes every line
after it `-`/`+`. An 8-line insertion into a 1,026-line file reported ~800 changed lines. Use it
only for same-length or last-lines-changed texts.

`read_git_diff(old, new)` / `read_git_diff(new)` (old side = same file at HEAD) returns
`diff_text, path1, path2` — one row, the whole diff as a string, ' '/'+'/'-' prefixed, no headers.
Same algorithm.

**[742af7b] `text_diff_lines(x)` ignores its argument and returns a hard-coded three-row sample
(`Hello / World / DuckDB`). `text_diff_stats(x)` takes one VARCHAR and returns the constant-shaped
string `lines_added: 1, lines_removed: 1, lines_modified: 1`; the docs' `(old, new)` overload and
STRUCT return do not exist.** Both are stubs in the shipped build. Do not use them; the docs
describe the fixed versions in 1223e5d.

What works for "what changed": land both versions as line tables and compare by content —

```sql
WITH b AS (SELECT unnest(string_split(content, chr(10))) AS l FROM read_text('git://src/x.cpp@main')),
     p AS (SELECT unnest(string_split(content, chr(10))) AS l FROM read_text('git://src/x.cpp@pr25'))
SELECT (SELECT array_agg(l) FROM (SELECT l FROM p EXCEPT ALL SELECT l FROM b)) AS added,
       (SELECT array_agg(l) FROM (SELECT l FROM b EXCEPT ALL SELECT l FROM p)) AS removed;
```

or `git_diff_tree` for the file list and `git_blame` on the region for who/when.

## Patterns that hold

```sql
-- files changed by a PR branch vs the base it will merge into
FROM git_diff_tree('.', 'main', 'pr25');
-- what main did to a file since the branch point
FROM git_diff_tree('.', 'pr25~1', 'main', path := 'src/quackapi_auth.cpp');
-- who owns the lines a PR inserts into, on main
SELECT commit_hash[1:8], author_name, author_date, array_agg(line_number) FROM git_blame('src/x.cpp', revision := 'main', min_line := 175, max_line := 215) GROUP BY ALL;
-- file at each commit (history of one path)
SELECT l.commit_hash, r.size_bytes FROM git_log() l LEFT JOIN LATERAL git_read_each(git_uri('.', 'README.md', l.commit_hash)) r ON true LIMIT 20;
-- CSVs in the repo, row counts, no checkout
SELECT t.file_path, count(*) FROM git_tree('HEAD') t, LATERAL read_csv(t.git_uri) d WHERE t.file_ext = '.csv' GROUP BY 1;
```

Performance: `git_log()` walks the whole history — `LIMIT`; filter before the LATERAL, not after;
`git_blame` with `min_line/max_line` only walks commits touching that range (cheap).

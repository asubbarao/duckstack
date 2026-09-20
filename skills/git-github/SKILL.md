---
name: git-github
description: >
  Git history and GitHub as tables — "readable git". duck_tails for any local repository
  (git_log, git_tree, git_read, git_status, blame, diffs, git:// paths at any revision), the gh
  extension for public GitHub metadata and gh:// file reads, and the gh CLI (authenticated) for
  private repos and raw file contents landed into DuckDB. Use when asked to read a repo, look at
  what changed, hit a GitHub URL, list issues/PRs, or compare files across commits.
argument-hint: "<repo path | owner/repo | github URL> [question]"
allowed-tools: Bash
---

Use both: the extensions when the data is public or local, `gh` when it is private or needs
your login. Everything lands as rows; `SQL-and-join beats stdout`. Read `/duckstack:duck`
§4 for the process rules — they apply to git data too (no `regexp_*` on messages, keep the
whole row, `array_agg` over `count`).

Both extensions are installed in `~/.duckdb/extensions` for the local client (verified 2026-09-17,
DuckDB 1.5.5: `duck_tails` 742af7b, `gh` 10d642a). They are **not** on the dev server; run
these in the `:memory:` client and, if a result should persist, a `quack_query` body (`/duckstack:quack`)
from a `COPY`/`INSERT … SELECT` of the client-side result, or attach dev and insert.

## Local repository — `duck_tails`

```sql
LOAD duck_tails;
-- git_log(repo_path := '.')  -> commit_hash, author_name, author_email, message, author_date, committer_*, parents...
SELECT commit_hash[1:8] AS sha, author_name, message, author_date
FROM git_log('.') LIMIT 5;                                 -- start small, then widen

-- git_tree(repo_path, ref) -> git_uri, repo_path, commit_hash, tree_hash, file_path, file_ext, ref,
--                              blob_hash, commit_date, mode, size_bytes, kind, is_text, encoding
--   Positional and in THAT order: git_tree('HEAD','.') fails with "Failed to resolve ref '.'".
--   repo_path is a named parameter of git_log/git_read/git_blame but NOT of git_tree.
--   file_ext CARRIES THE LEADING DOT ('.sql', '.md', '' for LICENSE, '.gitignore' for a
--   dotfile), so `= 'sql'` matches nothing and says nothing -- the quiet one.
--   kind is 'file' or 'tree': directory rows are included, so an unfiltered inventory
--   double-counts.
FROM git_tree('.', 'HEAD') WHERE file_ext = '.sql' AND kind = 'file';

-- git_read(path_or_uri, ..., repo_path) -> file contents at a revision; git:// works in readers too
SELECT * FROM read_csv('git://data/sales.csv@HEAD~1');

-- git_status(repo_path) -> repo_path, file_path, file_ext, status, status_flags, staged, unstaged, old_path
FROM git_status('.');

-- read_git_diff(uri_a[, uri_b]) / text_diff_stats(old, new) / diff_text(old, new)
FROM read_git_diff('git://README.md@HEAD', 'git://README.md@HEAD~1');

-- git_blame(file, use_mailmap, first_parent, revision, ignore_whitespace, min_line, max_line, repo_path)
FROM git_blame('skills/query/SKILL.md', repo_path := '.') LIMIT 20;
```

`*_each` variants take a relation of paths/refs — the correlated form for many files:
`FROM (SELECT file_path FROM git_tree('.', 'HEAD') WHERE file_ext = '.md' AND kind = 'file') t, git_read_each(t.file_path)`.

## Public GitHub — `gh` extension (no token; public only)

```sql
LOAD gh;
-- gh_repo('owner/repo' | 'owner/*') -> name, full_name, description, owner, private, fork, archived,
--   visibility, default_branch, language, license, homepage, html_url, topics[], stargazers_count,
--   watchers_count, forks_count, open_issues_count, size, created_at, updated_at, pushed_at
SELECT name, language, pushed_at, description FROM gh_repo('asubbarao/*') ORDER BY pushed_at DESC;

-- gh_issues(repo, state := 'open'|'closed'|'all') ; gh_prs(repo, state := ...) incl. author_association
SELECT number, title, labels FROM gh_issues('duckdb/duckdb-skills', state := 'all');

-- gh_repos((relation of 'owner/repo' strings)) -- the table-in-out form; feed it a CTE
WITH r AS (SELECT unnest(['duckdb/duckdb-skills', 'teaguesterling/duckdb_mcp']) AS repo)
SELECT full_name, pushed_at FROM gh_repos((FROM r));

-- gh:// filesystem: any reader over a file at a ref, globs included
FROM read_csv('gh://duckdb/duckdb@main/data/csv/glob/**/*.csv');
FROM read_text('gh://teaguesterling/duckdb_mcp@main/docs/reference/configuration.md');
```

A 404 from `gh_repo` means public-not-found — the repo may exist privately; switch to `gh`.

## Private, or authenticated — `gh` CLI, landed as rows

`gh` is logged in as `asubbarao-ifr` (org `inframe-risk`). Raw file contents:

```bash
gh api -H "Accept: application/vnd.github.raw" "repos/<owner>/<repo>/contents/<path>" > "$SCRATCH/<file>"
gh api "repos/<owner>/<repo>/git/trees/HEAD?recursive=1" > "$SCRATCH/tree.json"
gh api --paginate "repos/<owner>/<repo>/commits" > "$SCRATCH/commits.json"
```

then read them with readers, not with `jq` in the shell:

```sql
-- read_json(path, format := 'auto', records := 'auto', ...) -- let it infer; DESCRIBE first
SELECT t.path, t.type, t.size
FROM (SELECT unnest(tree) AS t FROM read_json('<scratch>/tree.json'));
FROM read_text('<scratch>/README.md');
```

Compare against upstream without leaving SQL: `gh api repos/<o>/<r>/compare/<base>...<head>`
→ `read_json` → `unnest(commits)`.

## Which to use

| Need | Tool |
|---|---|
| this checkout, any revision, diffs, blame | `duck_tails` |
| a public repo's metadata, issues, PRs, a file at a ref | `gh` extension |
| a private repo, org repos, API endpoints the extension lacks (compare, trees, search) | `gh` CLI → files → readers |
| the fork itself (`~/duckdb-skills`, `asubbarao-ifr/duckdb-skills`, private) | `duck_tails` locally; `gh` CLI remotely |

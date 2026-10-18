---
name: git-github
description: >
  Git history and GitHub as tables — "readable git". duck_tails for any local repository
  (git_log, git_tree, git_read, git_status, blame, diffs, git:// paths at any revision), the gh
  extension for public GitHub metadata and gh:// file reads, and curl through shellfs with the gh
  CLI's token for private repos and raw file contents, read straight into DuckDB readers. Use when asked to read a repo, look at
  what changed, hit a GitHub URL, list issues/PRs, or compare files across commits.
argument-hint: "<repo path | owner/repo | github URL> [question]"
allowed-tools: Bash
---

Use both: the extensions when the data is public or local, curl with `gh auth token` when it is
private or needs your login. Everything lands as rows; `SQL-and-join beats stdout`. Read `/duckstack:duck`
§4 for the process rules — they apply to git data too (no `regexp_*` on messages, keep the
whole row, `array_agg` over `count`).

Both extensions are loaded on the dev server (verified 2026-10-17: `duck_tails`, `gh` and
`shellfs` loaded); run these on the dev MCP. In a `:memory:` client,
`INSTALL duck_tails FROM community; LOAD duck_tails;` (and the same for `gh`).

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

`*_each` variants take a relation of paths/refs — the correlated form for many files. Feed them
`git_uri` (absolute); a bare `file_path` resolves against the server's cwd:
`FROM (SELECT git_uri FROM git_tree('<repo>', 'HEAD') WHERE file_ext = '.md' AND kind = 'file') AS md_files CROSS JOIN LATERAL git_read_each(md_files.git_uri)`.

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
WITH repos AS (SELECT unnest(['duckdb/duckdb-skills', 'teaguesterling/duckdb_mcp']) AS repo)
SELECT full_name, pushed_at FROM gh_repos((FROM repos));

-- gh:// filesystem: any reader over a file at a ref, globs included
FROM read_csv('gh://duckdb/duckdb@main/data/csv/glob/**/*.csv');
FROM read_text('gh://teaguesterling/duckdb_mcp@main/docs/reference/configuration.md');
```

A 404 from `gh_repo` means public-not-found — the repo may exist privately; switch to `gh`.

## Private, or authenticated — `gh` CLI, landed as rows

`gh` is logged in as `asubbarao-ifr` (org `inframe-risk`); `$(gh auth token)` supplies the
bearer token. The API response is the reader's source: curl through shellfs, no scratch file, no
`jq`, no clone (verified 2026-10-17 on `inframe-risk/inframe`: tree rows, the 8,277-character
`CLAUDE.md`, compare commits):

```sql
-- read_json(path, format := 'auto', records := 'auto', ...) -- let it infer; DESCRIBE first
SELECT entry.path, entry.type, entry.size
FROM read_json($cmd$curl -sSL --fail --max-time 30 -H "Authorization: Bearer $(gh auth token)" "https://api.github.com/repos/<owner>/<repo>/git/trees/HEAD?recursive=1" |$cmd$)
CROSS JOIN UNNEST(tree) AS t(entry);

-- a raw file
FROM read_text($cmd$curl -sSL --fail --max-time 30 -H "Authorization: Bearer $(gh auth token)" -H "Accept: application/vnd.github.raw" "https://api.github.com/repos/<owner>/<repo>/contents/<path>" |$cmd$);

-- compare against upstream
SELECT c.sha, c.commit.author.name, c.commit.message
FROM read_json($cmd$curl -sSL --fail --max-time 30 -H "Authorization: Bearer $(gh auth token)" "https://api.github.com/repos/<owner>/<repo>/compare/<base>...<head>" |$cmd$)
CROSS JOIN UNNEST(commits) AS t(c);
```

Many repos or paths in a column: one statement per row through `/duckstack:self-dispatch`, the
URL as a tera hole.

## Which to use

For a complete inventory of an account's open PRs, use the GitHub GraphQL
`user(login: ...).pullRequests(states: OPEN, first: 100)` connection and follow
`pageInfo` when needed. Verify current heads with `gh pr view`. On 2026-10-01,
`gh search prs --author asubbarao --state open` returned only three PRs while
the direct account connection returned all 24; search results alone did not
establish completeness. Preserve skipped, cancelled and absent checks separately
from success, and distinguish administrative checks from actual test execution.

| Need | Tool |
|---|---|
| this checkout, any revision, diffs, blame | `duck_tails` |
| a public repo's metadata, issues, PRs, a file at a ref | `gh` extension |
| a private repo, org repos, API endpoints the extension lacks (compare, trees, search) | curl through shellfs (`gh auth token`) → readers |
| the fork itself (`~/duckdb-skills`, `asubbarao-ifr/duckdb-skills`, private) | `duck_tails` locally; curl through shellfs remotely |

---
name: git-github
description: >
  Git history and GitHub as tables — "readable git". duck_tails for any local repository
  (git_log, git_tree, git_read, git_status, git_diff_tree, blame, git:// paths at any revision),
  the gh extension for public GitHub metadata and gh:// file reads, and the gh CLI (authenticated)
  for private repos, run logs and raw file contents landed into DuckDB. Use when asked to read a
  repo, look at what changed, review a PR, hit a GitHub URL, list issues/PRs, or compare files
  across commits.
argument-hint: "<repo path | owner/repo | github URL | PR URL> [question]"
allowed-tools: Bash
---

Use both: the extensions when the data is public or local, `gh` when it is private or needs
your login. Everything lands as rows; `SQL-and-join beats stdout`. Read `/duckdb-skills:duck`
§4 for the process rules — they apply to git data too (no `regexp_*` on messages, keep the
whole row, `array_agg` over `count`).

Both extensions are installed in `~/.duckdb/extensions` for the local client (verified 2026-09-17,
DuckDB 1.5.5: `duck_tails` 742af7b, `gh` 10d642a). `duck_tails` is also on the dev server
(`~/.duck/extensions`); `gh` is not. Run these in the `:memory:` client and, if a result should
persist, `dev.query($$CREATE TABLE …$$)` from a `COPY`/`INSERT … SELECT` of the client-side
result, or attach dev and insert.

## Local repository — `duck_tails`

```sql
LOAD duck_tails;
-- git_log([repo_path | 'git://repo@ref'])  -> repo_path, commit_hash, author_name, author_email, committer_name,
--   committer_email, author_date, commit_date, message, parent_count, tree_hash   (newest first; walks everything — LIMIT)
SELECT commit_hash[1:8] AS sha, author_name, message, author_date
FROM git_log('.') LIMIT 5;                                 -- start small, then widen

-- git_tree(ref) | git_tree(repo, ref) | git_tree('git://repo@ref') -> git_uri, repo_path, commit_hash, tree_hash, file_path,
--   file_ext ('.sql'), ref, blob_hash, commit_date, mode, size_bytes, kind ('file'|'directory'), is_text, encoding
FROM git_tree('HEAD') WHERE file_ext = '.sql';

-- git_read('git://repo/file@ref' [, max_bytes]) -> 16 cols incl. text / blob / truncated; git:// works in every reader
SELECT * FROM read_csv('git://data/sales.csv@HEAD~1');

-- git_diff_tree(repo_or_dir [, from_ref [, to_ref]], path := '', untracked := false)  UNDOCUMENTED
--   -> repo_path, file_path, file_ext, status ('added'|'deleted'|'modified'|'renamed'|'copied'|'typechange'), old_path
--   FIRST ARG IS A PATH, NEVER A REF. One ref = that ref vs the working tree. Two refs = commit-to-commit.
FROM git_diff_tree('.', 'main', 'pr25');                                       -- files a PR branch changes vs main
FROM git_diff_tree('.', 'pr25~1', 'main', path := 'src/quackapi_auth.cpp');    -- what main did to one file since the branch point

-- git_status([repo], untracked := false, ignored := false, path := '')  UNDOCUMENTED
--   -> repo_path, file_path, file_ext, status, status_flags, staged, unstaged, old_path
FROM git_status('.');

-- git_blame(file_or_uri, revision := 'HEAD', repo_path := '.', min_line := 1, max_line := last,
--           ignore_whitespace := false, use_mailmap := false, first_parent := false)
--   -> repo_path, file_path, file_ext, revision, line_number, line_content, commit_hash, author_name, author_email,
--      author_date, orig_commit_hash, orig_path, orig_line_number, boundary      (git_blame_hunks: one row per hunk)
SELECT commit_hash[1:8] AS sha, author_name, author_date, array_agg(line_number) AS lines
FROM git_blame('src/quackapi_auth.cpp', revision := 'main', min_line := 175, max_line := 215) GROUP BY ALL;

-- read_git_diff(old_uri, new_uri) -> diff_text (one string, ' '/'+'/'-' prefixed), path1, path2
FROM read_git_diff('git://README.md@HEAD~1', 'git://README.md@HEAD');
```

`*_each` variants take a column and bind only inside `LATERAL`:
`FROM git_tree('HEAD') t, LATERAL git_read_each(t.git_uri) r`,
`FROM git_log() l, LATERAL git_tree_each('.', l.commit_hash) t`,
`LEFT JOIN LATERAL git_read_each(git_uri('.', 'README.md', l.commit_hash)) r ON true` (keeps commits
where the file is absent). **Named parameters do not bind inside a LATERAL on 1.5.5** — `min_line
:= 1` is read as a column reference; use the positional forms there.

### Diff caveats (verified 2026-09-17, build 742af7b)

- `text_diff` / `diff_text` / `read_git_diff` are a **positional line walk, not Myers**: one
  inserted line marks every following line `-`/`+`. An 8-line insert into a 1,026-line file
  reported ~800 changes. Fine for same-length texts; useless for "what did this PR add".
- `text_diff_lines()` **ignores its argument** and returns a hard-coded 3-row sample.
  `text_diff_stats()` is a one-argument stub returning a constant string. The readthedocs pages
  (commit 1223e5d) describe fixed versions that are not in the installed build. Do not use either.
- What works: `git_diff_tree` for the file list, then land both versions as line tables and
  `EXCEPT ALL` them (see `references/duck_tails.md`), then `git_blame` the region.

`references/duck_tails.md` has the whole reconciled API and the review pattern used on
quackapi PR #25 (branch point → what main changed underneath → merge-tree → blame).

## Public GitHub — `gh` extension (no token; public only)

```sql
LOAD gh;
-- gh_repo('owner/repo' | 'owner/*') -> name, full_name, description, owner, private, fork, archived,
--   visibility, default_branch, language, license, homepage, html_url, topics[], stargazers_count,
--   watchers_count, forks_count, open_issues_count, size, created_at, updated_at, pushed_at
SELECT name, language, pushed_at, description FROM gh_repo('asubbarao/*') ORDER BY pushed_at DESC;

-- gh_issues(repo, state := 'open'|'closed'|'all') ; gh_prs(repo, state := ...) incl. author_association, head_sha, merged_at
SELECT number, title, labels FROM gh_issues('duckdb/duckdb-skills', state := 'all');

-- gh_repos((relation of 'owner/repo' strings)) -- the table-in-out form; feed it a CTE
WITH r AS (SELECT unnest(['duckdb/duckdb-skills', 'teaguesterling/duckdb_mcp']) AS repo)
SELECT full_name, pushed_at FROM gh_repos((FROM r));

-- gh:// filesystem: any reader over a file at a ref, globs included (whole file buffered; ** = one recursive Trees call)
FROM read_csv('gh://duckdb/duckdb@main/data/csv/glob/**/*.csv');
FROM read_text('gh://teaguesterling/duckdb_mcp@main/docs/reference/configuration.md');
-- private repos: CREATE SECRET (TYPE github, TOKEN getenv('GITHUB_TOKEN'));  scope defaults to gh://
```

A 404 from `gh_repo` means public-not-found — the repo may exist privately; switch to `gh`.

## Private, or authenticated — `gh` CLI, landed as rows

`gh` is logged in as `asubbarao-ifr` (org `inframe-risk`). Raw file contents, trees, commits,
compares, **and run logs** (those go to `/duckdb-skills:duck-hunt`):

```bash
gh api -H "Accept: application/vnd.github.raw" "repos/<owner>/<repo>/contents/<path>" > "$SCRATCH/<file>"
gh api "repos/<owner>/<repo>/git/trees/HEAD?recursive=1" > "$SCRATCH/tree.json"
gh api --paginate "repos/<owner>/<repo>/commits" > "$SCRATCH/commits.json"
gh run list -R <owner>/<repo> --limit 10                              # run ids, conclusions
gh api "repos/<owner>/<repo>/actions/runs/<run_id>/logs" > "$SCRATCH/run.zip"   # → duck_hunt
git fetch origin pull/<N>/head:pr<N>                                  # a PR as a local ref for duck_tails
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
| this checkout, any revision, file lists, blame, working-tree status | `duck_tails` |
| a PR: files vs base, what base changed underneath, who owns the region | `git fetch pull/N/head:prN` + `git_diff_tree` + `git_blame` |
| a public repo's metadata, issues, PRs, a file at a ref | `gh` extension |
| a private repo, org repos, API endpoints the extension lacks (compare, trees, search, run logs) | `gh` CLI → files → readers / duck-hunt |
| the fork itself (`~/duckdb-skills`, `asubbarao-ifr/duckdb-skills`, private) | `duck_tails` locally; `gh` CLI remotely |

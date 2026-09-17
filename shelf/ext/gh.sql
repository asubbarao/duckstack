-- @ext: gh
-- @rev: 10d642a (community, carlopi/duckdb-gh, DuckDB 1.5.5); local client only
-- @verified: 2026-09-17 (functions listed; public reads); private repos need a github secret
-- @functions: gh_repo, gh_repos, gh_issues, gh_prs, gh:// filesystem
-- @needs: httpfs; CREATE SECRET (TYPE github, TOKEN …) or GITHUB_TOKEN for private repos and the 5,000/h limit
-- @tags: github, repository metadata, pull requests, issues, read a file at a ref, stars
-- @summary: GitHub metadata as tables and gh:// as a filesystem: any reader over a file at a ref, globs included.
--   For run logs, compare, trees and search the extension has no function — use the gh CLI → files → readers.
LOAD gh;
CREATE SECRET gh_tok (TYPE github, TOKEN getenv('GITHUB_TOKEN'));     -- scope defaults to gh://

-- gh_repo('owner/repo' | 'owner/*') -> name, full_name, description, owner, private, fork, archived, visibility,
--   default_branch, language, license, homepage, html_url, topics[], stargazers_count, watchers_count, forks_count,
--   open_issues_count, size, created_at, updated_at, pushed_at
SELECT name, language, pushed_at FROM gh_repo('asubbarao/*') ORDER BY pushed_at DESC;

-- gh_prs(repo, state := 'open'|'closed'|'all') -> 22 cols incl. number, title, state, author_association, head_sha, merged_at
SELECT number, title, merged_at, head_sha[1:8] FROM gh_prs('inframe-risk/inframe', state := 'all') ORDER BY merged_at DESC NULLS LAST LIMIT 10;
SELECT number, title, labels FROM gh_issues('duckdb/duckdb-skills', state := 'all');

-- Table-in-out: feed a relation of repos
WITH r AS (SELECT unnest(['duckdb/duckdb-skills', 'teaguesterling/duck_hunt', 'teaguesterling/duck_tails']) AS repo)
SELECT full_name, pushed_at, stargazers_count FROM gh_repos((FROM r));

-- gh://owner/repo[@ref]/path — whole file buffered; ** is one recursive Trees call (truncated flag unchecked)
FROM read_text('gh://teaguesterling/duck_hunt@main/docs/custom-parsers.md');
FROM read_csv('gh://duckdb/duckdb@main/data/csv/glob/**/*.csv');

-- A 404 from gh_repo means public-not-found; the repo may exist privately.

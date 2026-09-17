# shelf (was duckdb-flying)

Moved into the duckdb-skills plugin by ADR-002 so a skill and the SQL it summarizes change in one commit.

One `.sql` file per DuckDB extension, each verified on this machine (DuckDB 1.5.5 osx_arm64), each
self-describing, and one query that finds the right one.

```
ext/<extension>.sql     the calling convention that actually binds, with the traps named
catalog.sql             reads ext/*.sql → flying_header, flying_lines, FTS index → find_sql(q), sql_for(name)
```

## Find one

```sql
-- from the plugin root:  FLYING_ROOT="$PWD/shelf" duckdb :memory: -cmd ".read shelf/catalog.sql"
FROM find_sql('which files changed in a pull request');   -- ranked: file, ext, score, summary, matching lines
FROM find_sql('post a query to myself per row');          -- → quackapi.sql, http_client.sql
FROM sql_for('read_cloudwatch_logs');                     -- by extension, function, or tag
SELECT ext, verified, functions FROM flying_header;       -- the whole shelf
```

`find_sql` is also the shape of an MCP tool: `PRAGMA mcp_publish_tool('find_sql', …)` on the dev
sidecar and every agent on this machine gets it.

## The header contract

Every file starts with `-- @key: value` lines; `catalog.sql` reads nothing else.

```
-- @ext: duck_tails
-- @rev: 742af7b (community, DuckDB 1.5.5 osx_arm64)
-- @verified: 2026-09-17 on <repo>
-- @functions: git_log, git_tree, git_diff_tree, …
-- @needs: a local checkout
-- @tags: git, blame, pull request, what changed
-- @summary: one paragraph; continuation lines start with `--   `
```

`@verified` is a date and a target, not a promise. A file whose `@rev` no longer matches
`duckdb_extensions().extension_version` is due for a re-run.

## Files

| ext | what it settles |
|---|---|
| `quackapi` | self-dispatch: `CREATE ROUTE q POST '/q' AS SELECT * FROM query($sql)` + `quackapi_serve` + `http_post` per row — the query is the orchestrator |
| `http_client` | `http_get`/`http_post` per row (Linear GraphQL, the dispatch POST), `http_head` for response headers |
| `httpfs` | GET JSON APIs as tables with http secrets: GitHub, Sentry, Slack; windows `-1h` / `-1d` / a backfill day |
| `ducklake` | the landing catalog: local metadata + parquet, snapshots, time travel, dedupe as a view |
| `cronjob` | the '1 hour' and '1 day' jobs on dev, same statements as the hand-run artifact |
| `cloudwatch` | prod ECS + RDS logs, Insights, metrics, alarms; windowed, day-partitioned |
| `duck_tails` | git as tables; `git_diff_tree` is a path-first function; the diff functions are stubs in 742af7b |
| `duck_hunt` | CI run ZIPs → step tree + tool events; the pytest-xdist `regexp:` reader; a custom parser for inframe's log shape |
| `sitting_duck` | AST as rows; `.call#name` callers; densest files |
| `gh` | GitHub metadata tables and `gh://` reads |
| `duckdb_mcp` | publish the lake to agents; call Slack/Linear MCP servers from SQL |

## Where it runs

Local client: everything. Dev server (`quack:localhost:9494`): what `setup.sql` loads — httpfs,
ducklake, cronjob, cloudwatch, otlp, prometheus, duck_tails; not http_client, duck_hunt,
sitting_duck, gh, quackapi. A file says which in `@needs`.

---
name: self-dispatch
description: Run SQL that writes SQL and executes it on the same dev DuckDB — per-row table functions (ls, read_csv, read_lines on a path column), crawls, fan-outs, ordered DDL. Use whenever a table function refuses a column argument, when work repeats per row, or when a stage depends on the rows of the one before.
allowed-tools: mcp__dev__query_with_limit, mcp__dev__query_no_limit, mcp__dev__dispatch_sql, mcp__dev__self_dispatch, mcp__dev__dispatch_sequence
---

# Self-dispatch

A table function such as `ls(path)` or `read_csv(path)` takes a literal, not a column. Self-dispatch
gets around it without a loop, a script or a second server: one CTE writes the statement for each
row as text and posts it to this same server's `/sql` route; the next CTE unnests the receipts back
into rows. The database writes the statement it cannot bind, then runs it.

## The molecule: statements, request maps, receipts

Use `references/selfdispatch.sql` for the minimal executable comparison:

```sql
WITH statements AS (
    SELECT n AS source_key, 'SELECT ' || n || ' AS answer' AS q
    FROM generate_series(1, 4) AS numbers(n)
), requests AS (
    SELECT *, MAP {'sql': q} AS form FROM statements
), posted AS (
    SELECT *, http_post_form('http://127.0.0.1:9495/sql', MAP {}, form) AS receipt
    FROM requests
), packed AS (
    SELECT array_agg(posted) AS receipts FROM posted
)
SELECT item.*
FROM packed CROSS JOIN UNNEST(receipts) AS r(item);
```

`http_post_form(url, headers, form)` accepts two VARCHAR maps. `/sql` expects
`MAP {'sql': q}`; a route explicitly configured with a `q` parameter expects
`MAP {'q': q}`. Use the selected existing endpoint, never create another server
for dispatch. Keep source keys and statements beside receipts.

For large SQL bodies, use `http_post(url, MAP {'Content-Type': 'application/json'},
json_object('sql', q))`; form encoding has an approximately 8 KB request cap.
Build each statement directly, or use an array of readable SQL clauses joined
with spaces. Do not split every keyword into prefix/suffix settings, add a
transport registry, or nest generated Quack calls. Tera is unnecessary here.

`references/dispatch.sql` applies this pattern to home-directory metadata.
Chain stages from the previous results when their work depends on those results;
an aggregate or array position alone does not guarantee concurrency or ordering.

## Worked example: crawl a tree, pruning before descending

`references/declarative_ls.sql` is the whole thing, verified 2026-09-28 on `~/duckdb-skills`
(10 → 64 → 48 paths over three waves, every receipt 200, nothing read under `.git`):

1. `wave1`: `ls(root)` with `is_dir(path)`, `file_name(path)` beside it.
2. `post2`: one `ls('<folder>')` statement per folder that survives
   `NOT starts_with(name, '.') AND name NOT IN ('node_modules', '__pycache__', 'venv')`.
3. `wave2`: the receipts unnested. Repeat 2–3 for each further level.

The filter sits **before** the dispatch, so a pruned folder is never listed. Filtering the output of
`lsr(root)` is the opposite: it walks all of `.venv` first. Keep the complete SQL inline where it executes; do not read a SQL file and post its contents.

## Cache receipts: the receipt table is the cache

`references/cached_dispatch.sql` (verified 2026-10-07) wraps each dispatched statement in
`INSERT INTO dispatch_cache BY NAME SELECT <md5>, <stmt>, to_json(list(t)), now() FROM (<stmt>) t RETURNING …`,
so the statement stores its own answer and returns it. The outer query anti-joins against receipts
younger than the TTL and posts only the misses. Run 2 of the same query made zero posts. Dedupe is
`DISTINCT` on the generated statement text before the post: `array_agg(DISTINCT http_post(…))` still
makes every call. quackapi has no result cache of its own, so this table is the cache layer.
Cache reads only.

## Traps (measured)

- `http_post` sends one post at a time within a chunk (inner `now()` stamps 0.9–1.7 s apart),
  and its read timeout is hardcoded at **10 s** (httpclient `client.set_read_timeout(10, 0)`):
  a longer post returns status -1 "Error reading response" while the server finishes the work
  anyway. Long or parallel work goes through `curl` in shellfs (`read_json('curl -sS --max-time N -X POST
  …/sql -H content-type:application/json --data-binary @- <<''EOF'' … EOF |')`, `curl --parallel` for a
  batch); quackapi is serve-only and its client functions are being removed (Alok, 2026-10-08). The
  10 s limit itself is fixed upstream in query-farm/httpclient, not by another client.
- A status -1 is an uncertain write, not a failed one: check the target table before anything
  is re-posted (2026-10-07: every row landed about 14 s after the client gave up).
- `/sql` answers **200 `[]`** to SQL that does not parse (`SELEC 1`, or a column named `at`, now
  reserved). An empty body is not proof the statement ran.
- `quack_query` cannot be the transport: it is a table function, so its SQL must be a literal.
- A shellfs pipe's exit code is its **last** command's. A non-zero exit raises and discards the
  output, but every earlier command in the pipe already ran. Put the command whose receipt matters
  last, redirect each write's response to a file, and after an error read that file before
  re-posting anything (2026-10-08: a `gh api PUT` landed, then a mistyped `jq` path exited 127).
- The dev process has no shell PATH: resolve binaries with `command -v x` through shellfs first;
  `gh` is `/opt/homebrew/bin/gh`, `jq` is `/usr/bin/jq`, `codex` is `~/.local/bin/codex`.

- `/sql` caps an unlimited SELECT at **20 rows**, silently. Every dispatched SELECT gets its own
  outer `LIMIT`, or returns `array_agg` of its rows as one value.
- The receipt body is a JSON array inside a string: `from_json(receipt ->> '$.body', '[{…}]')`.
- A failed statement is a receipt with a non-200 status and the error in its body; keep it as a row.
- Large bodies: don't `array_agg` tens of MB of receipts; post one row each instead and tabulate `r.status`.
- Dependent DDL (create → alter → insert) goes in one ordered body (`dispatch_sequence`), not as
  parallel rows, which can run out of order.
- A path containing `'` breaks the `printf` quoting; double it with `replace(path, chr(39), chr(39) || chr(39))`.

Never: `SET VARIABLE` as orchestration, `WITH RECURSIVE`, `AS MATERIALIZED`, `LEFT JOIN LATERAL
UNNEST`, a second server, or a shell loop around DuckDB. If dev itself misbehaves, restart it
(the `light-switch` skill) rather than working around it.

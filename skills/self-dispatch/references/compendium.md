# Self-dispatch: SQL construction and execution

The program is ordinary DuckDB SQL. Tera only makes its text easier to construct.
SQL selects rows, computes values and decides what runs; a template only fills holes, with no
`{% if %}` and no `{% for %}` over options. Use one of the five named templates in
[../templates/](../templates/canonical.sql) when the statement has that shape, an inline template otherwise.
Do not introduce a generic command language or a dispatch macro to hide these steps.

## The shape

```sql
WITH answers AS (                        -- 1. declare every value
    SELECT n FROM range(42, 44) AS r(n)
), rendered AS (                         -- 2. one statement per row; Tera fills holes
    SELECT n, tera_render('SELECT {{ n }} AS answer', a::JSON, autoescape := false) AS sql
    FROM answers AS a
), dispatched AS (                       -- 3. post them; keep the sql beside its receipt
    SELECT array_agg({sql: sql, receipt: selfdispatch(sql)}) AS receipts FROM rendered
)
SELECT r.sql, unnest(r.receipt) FROM dispatched CROSS JOIN UNNEST(receipts) AS t(r);
```

Construction produces an `sql` column. Execution posts that column, collects receipts
and unnests them. To inspect without executing, end at `SELECT * FROM rendered`.
The endpoint is this machine's dev (`selfdispatch` wraps `quackapi_post` to `127.0.0.1:9495/sql`).

## Construction cases

| Case | Template / working source | What the first CTE declares |
|---|---|---|
| Plain SELECT | inline `SELECT {{ n }} AS answer` | Values or already quoted identifiers |
| Native file reader | inline, [inline.sql](inline.sql) example 2 | Reader name, `quote_literal`ed source, options as text (`', header := true'`) |
| One shell command | `shell.tera` | Reader, command text, options text |
| Output read_json cannot read whole | `jq_array_to_lines.tera` | Command text, path to the array |
| Another host | `network.tera` | Reader, quoted URL, options text |
| Ordered SQL statements | [replica/pull.sql](../../../server/replica/pull.sql) | Source, target, quoted table name and temporary marker |
| Same query, different catalog | [replica/reads.sql](../../../server/replica/reads.sql) | Route name, path and catalog |
| Fetch URL rows | [crawl_rows.sql](../../crawl/references/crawl_rows.sql) | Selected URLs and fetch policy |
| Refresh session files | [setup.sql](../../../server/setup.sql) | Changed session files, destination and quoted directory |

Reader options are one text column, never a map looped in the template: an option list that
varies per row is a different string per row, written in SQL.

## Execution cases

- **Rows → posts → receipts:** the shape above is the common tail for every construction case.
- **Keep source identity:** aggregate `{key: key, sql: sql, receipt: selfdispatch(sql)}`.
- **Results are `receipt.*`:** never parse the body with a `from_json` structure string or `->>`.
  When the next stage needs the rows as columns, each statement writes them (`COPY … TO`) and the
  next stage reads the files ([inline.sql](inline.sql) example 3). Keep failed receipts as rows.
- **Dependent writes:** send one ordered multi-statement body. Aggregating posts does not
  establish execution order. Independent rows may dispatch independently.
- **Boot plus cron:** define one complete SQL body and use it for the initial post and `cron`.
  The active setup uses this for per-session copies followed by rebuilding `agent.lines`.
- **A table function that needs a column** (`read_lines`, `read_csv`, `git_read`, `crawl`): render
  a literal statement per row and dispatch it. No `read_*_lateral`, no lateral join.

## Keyed writes and the actual dispatch review

```sql
MERGE INTO lake.agents.ext_fetch AS target
USING fetched AS source
ON target.url = source.url AND target.fetched_at = source.fetched_at
WHEN NOT MATCHED THEN INSERT BY NAME;
```

Here `fetched` is the query producing `url, fetched_at, response`; the actual programs inline
that query in `USING`. They do not add a helper table. Replacing an existing observation is
a different policy; the dispatch logs use ignore so a replay cannot overwrite its first receipt.

Checked on dev, 2026-10-16: 2,840 fetch rows, 2,840 distinct keys, no null key fields and no
duplicate keys. Rechecked 2026-10-17: two keys (nanoarrow, erpl_odata at 04:02:29) now have two copies,
so some writer is not going through the MERGE. Replaying a rendered fetch twice inside a transaction left one fixture row;
rollback removed the fixture. The replica's 9511 listener and database file are absent, so
its persisted rows could not be checked. Its schema now creates the unique index; existing
duplicates would fail index creation visibly rather than being silently discarded.

Duplicate checks (run the second on the replica, not dev):

```sql
SELECT url, fetched_at, len(array_agg(response)) AS copies
FROM lake.agents.ext_fetch GROUP BY url, fetched_at HAVING copies > 1;

SELECT run_started, table_name, len(array_agg(run_id)) AS copies
FROM pull_log GROUP BY run_started, table_name HAVING copies > 1;
```

[review.sql](review.sql) applies native SQL parsing and Sitting Duck to the actual server,
replica, crawl and inline-example programs. It also opens dollar-quoted cron/boot SQL.
Whole-file native parsing succeeds for pull, reads, crawl and the inline examples.
The CLI `.bail` and server extension syntax need separate inspection. Tree-sitter emits
ERROR nodes for valid DuckDB SQL and misses some calls inside those subtrees; candidate
identifiers and errors remain visible. A missing AST call is not proof that no post exists.

The reviewed cases include docs fetching, profile-file export, MCP forwarding, session
copy/view refresh, replica table copying, route creation and scheduled posts. The profile
export now uses the same native sender and a named Tera substitution instead of positional
`printf`. Its generated COPY was executed and the JSON file read back. Full service boot
and the offline replica were not run during this review.

## What the existing dispatch inventory actually contains

The 2026-10-15 parser-tools/AST and URLPattern inventory has 1,213 distinct statements:
983 SQL senders, 65 readers containing an endpoint, and 165 endpoint references.
Those last two groups are candidates, not proof that every row executes a self-dispatch.

| Observed transport | Distinct statements using only that sender | Current treatment |
|---|---:|---|
| `quack_query` | 426 | Direct remote SQL; literal binding differs from a scalar self-post |
| `http_post` | 331 | Historical JSON HTTP sender |
| `http_post_form` | 115 | Historical form sender; avoid the form-body size limit |
| `quackapi_post` | 107 | Native scalar JSON sender; `selfdispatch` wraps it in the examples above |
| Mixed senders | 4 | Historical compositions |

Source: [dedupe query](/Users/aloksubbarao/tmp/selfdispatch-dedupe-20261015.sql) and
[captured statements](/Users/aloksubbarao/tmp/selfdispatch-deduplicated-20261015.parquet).
The query parses recorded SQL and classifies localhost execution URLs; it never executes
recorded statements. This is a dated inventory, not a claim of an exhaustive current filesystem scan.
The earlier curl readers and MCP JSON-RPC posts are transport variants, not new template languages.

## Quoting, writes and failures

- `c::JSON` constructs the context; no handwritten JSON. `autoescape := false` disables HTML
  escaping, not SQL or shell escaping.
- `quote_literal(col)` wraps a value in single quotes.
  A descriptive `lit` column is fine. Quote identifiers with double quotes and escape embedded ones.
- Dollar quotes keep programs readable; their chosen delimiter must not appear in the enclosed text.
- `pull_log` is keyed by `(run_started, table_name)`: one receipt per table per pull.
  Both key columns are non-null in the schema; a unique index enforces the key and
  `INSERT OR IGNORE INTO pull_log BY NAME` preserves the first receipt for that attempt.
  `run_id` is only a display label rounded to seconds, so it is not the identity.
- `ext_fetch` is keyed by `(url, fetched_at)`: distinct fetch observations remain distinct.
  The timestamp is prepared before rendering, so replaying the same generated SQL retains its key.
  DuckLake rejects unique indexes and constraint-based `OR IGNORE`; use the standard SQL
  `MERGE` below to ignore observations already present. This matches the source against the
  current snapshot; it does not introduce a database-wide uniqueness constraint.
- Empty input produces no posts. Preserve status, body and error. A 200 transport response alone
  does not verify the intended rows/files. Do not automatically retry an uncertain write.
- Shell pipelines normally report the last stage’s exit status. Use an explicit Bash `pipefail`
  program when an upstream failure must fail the whole command.

Runnable inline cases: [inline.sql](inline.sql). No new macros or tables are required.

## Historical transport measurements

These observations predate this rewrite; they are retained as evidence, not alternate default recipes.

## Senders compared (dev, 2026-10-12; N rows × 200 ms, peak = max overlapping rows)

| sender | types | peak (N=64) | lost | why (source, pinned to dev's versions) |
|---|---|---|---|---|
| curl in `read_lines_lateral` (A) | JSON | 9 (threads=10); 13 at threads ≥16 | 0 | pipes run serially per task (read_lines.cpp:856-907); width comes from the delim HASH_GROUP_BY, ≤16 partitions (radix_partitioned_hashtable.cpp:130, 690-709); identical cmds run once |
| constructed `read_json([curl…])` | inferred | 8 from dev; 29 from a `:memory:` client at threads 32 | 0 | multi-file reader: one file per thread (multi_file_function.hpp:525) |
| constructed `read_arrow([curl…])` (B) | native | not measured | – | same multi-file shape expected; measure before relying on it |
| `http_post` / `http_post_form` | JSON | 1 (serial) | 0 | synchronous per row, new client each call (http_client_extension.cpp:336/380); a scalar is parallel only when the source has several tasks (put a GROUP BY in front: 2/4/12 at threads 2/4/16); 10 s read timeout (line 60) |
| `quackapi_post` | JSON | all at once | 0 of 64 on quackapi 269c7b2 | fans out min(rows,32) threads with pooled keep-alive clients (quackapi_http_fetch.cpp:28, 624-641). The losses (8 of 32, 34 of 64; "Could not establish connection") were the server's listen backlog of 5 in the old build ed4552b, fixed by quackapi #39 (2e19586): `netstat -Lan` maxqlen 5 → 128. Same client, same 64 rows: 64/64 against 269c7b2. Plain curl never showed it because xargs-spawned curls arrive staggered |
| `quack_query` | native | 1 (serial) | 0 | all remote work happens in Bind, single planning thread (quack_scan.cpp:16-65) |
| Flight SQL via `adbc_scan` | native | 1 per client | rows lost per-row | one operation per ATTACH (adbc_connection.hpp:21-33); duckflight cancels a client's running statement when another client sharing the token exits |
| Airport | native | – | – | scans remote tables only; cannot send SQL |

Server ceiling for every HTTP sender: quackapi's cpp-httplib pool is 32 workers (quackapi_server.hpp:28),
minus the ones the caller holds; idle keep-alive sockets hold workers for 10 s, so overflow shows as
10 s stalls. The /sql → quack hop does not serialise (quack ThreadPool(128), per-session lock only).

Traps:
- Self-dispatch is a plain SELECT; nothing needs a COPY. Only when results are also written out in
  order (`COPY … TO` with `preserve_insertion_order=true`, the CLI default) does the lateral shape
  turn fully serial; `SET preserve_insertion_order = false` before such a COPY. `~/.duckdbrc` sets
  threads=4 for ad-hoc CLIs.
- A scalar sender (`http_post`) runs on whichever thread holds the row. `range()`, VALUES and short
  lists are one unit of work, so one thread makes every call in turn (measured: 8 × 200 ms =
  2.04 s; the same 8 rows after a GROUP BY = 0.78 s; 8 rows filtered from range(65536) = 1.66 s).
- Width of the constructed program = the orchestrator's threads. For more than ~8 at once, run it
  from a `duckdb :memory:` client with `SET threads = 32`, not inside dev.

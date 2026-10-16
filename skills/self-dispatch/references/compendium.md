# Self-dispatch: SQL construction and execution

The program is ordinary DuckDB SQL. Tera only makes its text easier to construct.
SQL selects rows, computes values and decides what runs. A template should be easy to
replace with `concat`, `replace` or `string_agg` without redesigning the query.
Use inline templates for short programs; named files for a shared, readable SQL body.
Do not introduce a generic command language or a dispatch macro to hide these steps.

## The two parts

```sql
WITH statements AS (
    SELECT n, tera_render('SELECT {{ n }} AS answer',
                          c::JSON, autoescape := false) AS sql
    FROM range(42, 44) AS c(n)
), posted AS (
    SELECT array_agg({sql: sql, receipt: quackapi_post(
        'http://127.0.0.1:9495/sql', json_object('sql', sql)::VARCHAR)}) AS receipts
    FROM statements
)
SELECT r.sql, unnest(r.receipt) FROM posted CROSS JOIN UNNEST(receipts) AS t(r);
```

Construction produces an `sql` column. Execution posts that column, collects receipts
and unnests them. To inspect without executing, end at `SELECT * FROM statements`.
The endpoint above is this machine’s selected dev. The replica uses its own 9511 endpoint.

The pure SQL replacement for the render expression above is just
`concat('SELECT ', n, ' AS answer')`. No Tera-specific execution mechanism remains.

## Construction cases

| Case | Template / working source | What SQL supplies |
|---|---|---|
| Plain SELECT | `SELECT {{ n }} AS answer` | Values or already quoted identifiers |
| Native file reader | `SELECT * FROM read_csv({{ source }}, header := {{ header }})` | SQL-quoted source and typed options |
| Command → CSV | [find.sql.tera](find.sql.tera) | Argument list and named reader options |
| Repeated commands → JSON | [json-pipelines.sql.tera](json-pipelines.sql.tera) | One argument list per command; template visibly contains `seq` and `jq` |
| Arbitrary pipeline | [inline.sql](inline.sql), example 4 | Arrays of shell-quoted argument arrays |
| Ordered SQL statements | [replica/pull.sql](../../../server/replica/pull.sql) | Source, target, quoted table name and temporary marker |
| Same query, different catalog | [replica/reads.sql](../../../server/replica/reads.sql) | Route name, path and catalog |
| Fetch URL rows | [crawl_rows.sql](../../crawl/references/crawl_rows.sql) | Selected URLs and fetch policy |
| Refresh session files | [setup.sql](../../../server/setup.sql) | Changed session files, destination and quoted directory |

### Native readers and optional := parameters

```sql
WITH c AS (
    SELECT concat(chr(39), '/Users/aloksubbarao/file.csv', chr(39)) AS source,
           {'header': false, 'all_varchar': true, 'delim': $$','$$} AS params
)
SELECT tera_render($t$
SELECT * FROM read_csv({{ source }}
{% for name, value in params %}, {{ name }} := {{ value }}{% endfor %});
$t$, c::JSON, autoescape := false) AS sql FROM c;
```

An empty `MAP(VARCHAR, VARCHAR)` supplies no options. Values here are SQL expressions:
booleans and numbers render directly; a text option includes SQL quotes. Reader names
and option names are authored code. Use fixed options directly when they do not vary.

### Named command template

```sql
WITH source AS (
    SELECT ['/private/tmp', '-maxdepth', '0', '-type', 'd'] AS args,
           {'header': false, 'all_varchar': true} AS params
), c AS (
    SELECT list_transform(args, arg ->
        concat(chr(39), replace(arg, chr(39), $$'"'"'$$), chr(39))) AS args, params
    FROM source
)
SELECT tera_render('find.sql.tera', c::JSON, autoescape := false,
    template_path := '/Users/aloksubbarao/duckdb-skills/skills/self-dispatch/references/*.tera') AS sql
FROM c;
```

The entire file is:

```sql
SELECT * FROM read_csv($cmd$find {{ args | join(sep=" ") }} |$cmd$
{% for name, value in params %}, {{ name }} := {{ value }}{% endfor %});
```

That renders recognizable SQL. It can equally be pasted inline. A plain SQL equivalent
joins `args` with spaces and aggregates the option names/values with ` := `.
The quoting expression protects each shell argument, including spaces and apostrophes.
The pipe is visible in the template; it is not hidden inside argument data.

### Repeated commands with a simple jq pipe

```sql
WITH c AS (SELECT [['2'], ['3', '3']] AS commands)
SELECT tera_render('json-pipelines.sql.tera', c::JSON, autoescape := false,
    template_path := '/Users/aloksubbarao/duckdb-skills/skills/self-dispatch/references/*.tera') AS sql
FROM c;
```

The entire file is:

```sql
SELECT * FROM read_json($cmd$
{% for args in commands %}seq {{ args | join(sep=" ") }} | jq -Rc '{id: tonumber}'
{% endfor %}|$cmd$, format := 'newline_delimited');
```

Executed on dev: IDs 1, 2, 3. These arguments are fixed numeric examples; quote external
arguments as in the find example. Change the command-specific template to show the real
command rather than hiding it behind a large conditional template.

## Execution cases

- **Rows → posts → receipts:** the first example is the common tail for every construction case.
- **Keep source identity:** aggregate `{key: key, sql: sql, receipt: quackapi_post(...)}`.
- **Consume JSON rows:** keep the receipt, then expand its successful JSON body in the next stage.
  Do not drop failed receipts from the diagnostic result.
- **Dependent writes:** send one ordered multi-statement body. Aggregating posts does not
  establish execution order. Independent rows may dispatch independently.
- **Boot plus cron:** define one complete SQL body and use it for the initial post and `cron`.
  The active setup uses this for per-session copies followed by rebuilding `agent.lines`.
- **Direct correlated reader:** use `CROSS JOIN LATERAL read_lines_lateral(c.command)` when
  supported; that is a reader call, not itself a self-post.

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
duplicate keys. Replaying a rendered fetch twice inside a transaction left one fixture row;
rollback removed the fixture. The replica's 9511 listener and database file are absent, so
its persisted rows could not be checked. Its schema now creates the unique index; existing
duplicates would fail index creation visibly rather than being silently discarded.

[review.sql](review.sql) applies native SQL parsing and Sitting Duck to the actual server,
replica, crawl and inline-example programs. It also opens dollar-quoted cron/boot SQL.
Whole-file native parsing succeeds for pull, reads, crawl and the four inline examples.
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
| `quackapi_post` | 107 | Native scalar JSON sender used in the examples above |
| Mixed senders | 4 | Historical compositions |

Source: [dedupe query](/Users/aloksubbarao/tmp/selfdispatch-dedupe-20261015.sql) and
[captured statements](/Users/aloksubbarao/tmp/selfdispatch-deduplicated-20261015.parquet).
The query parses recorded SQL and classifies localhost execution URLs; it never executes
recorded statements. This is a dated inventory, not a claim of an exhaustive current filesystem scan.
The earlier curl readers and MCP JSON-RPC posts are transport variants, not new template languages.

## Quoting, writes and failures

- `c::JSON` constructs the context; no handwritten JSON. `autoescape := false` disables HTML
  escaping, not SQL or shell escaping.
- `concat(chr(39), col, chr(39))` is fine for known text without apostrophes. For arbitrary SQL
  strings, double embedded apostrophes with `replace(col, chr(39), chr(39)||chr(39))`.
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

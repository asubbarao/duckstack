---
name: query
description: >
  Run SQL on the dev quack (or another explicitly selected door) or ad-hoc against files.
  Accepts raw SQL, a natural-language question, or a path to a .sql artifact. One statement
  runs with `duckdb :memory: -c`; anything longer is a single .sql artifact run by path with
  `-f` — no state file, the ATTACH is in the head. Uses DuckDB Friendly SQL and this user's
  SQL process rules; `--#` lines in an artifact are the human's instructions.
argument-hint: <SQL | question | path.sql> [--file data-path] [--door dev|dev-ro|quack:host:port]
allowed-tools: Bash
---

You are helping the user query data on the duckstack. Read `/duckdb-skills:duck` §2 (boundary),
§3 (client forms) and §5 (process rules) first; they bind every statement you write.

Input: `$@`

## Step 1 — Determine the mode

- **Artifact mode**: the input is a path to a `.sql` file. Read it; collect every line starting
  with `--#` — that is the instruction set (human → agent). Act on them, then execute the file
  by path (Step 5). Never depend on the human having run it in their IDE; you run it.
- **Ad-hoc file mode**: `--file` present, or the SQL references file paths (`FROM 'x.csv'`).
  Runs sandboxed in the local client (Step 5).
- **Session mode** (default): everything else — table names, natural language, SQL without
  file references. The target is `dev` (`quack:localhost:9494`) unless `--door` says otherwise.

Head for every dev statement (token on the shell line, never in SQL):

```bash
QUACK_TOKEN="$(cat ~/.duck/token)" duckdb :memory: -c "
LOAD quack;
ATTACH 'quack:localhost:9494' AS dev (TYPE quack, TOKEN getenv('QUACK_TOKEN'));
<statement>"
```

If the attach fails ("connection refused"), the launchd job may have restarted — run once more,
then report. Do not fall back to opening `~/.duck/dev.duckdb`; it is locked by design.

## Step 2 — Check DuckDB is installed

```bash
command -v duckdb
```

If not found, delegate to `/duckdb-skills:install-duckdb` and then continue.

## Step 3 — Generate SQL if needed

Natural language → read the schema **from the server** first:

```sql
FROM dev.query($$SELECT table_name, estimated_size, column_count FROM duckdb_tables() WHERE NOT internal ORDER BY 1$$);
FROM dev.query($$DESCRIBE <table_name>$$);
```

Then write the query with the Friendly SQL reference below **and** the process rules:

- readers infer schema; `DESCRIBE` first; select by name — no `col0`, no `p[-4]`, no
  `split_part` on a path, no `json_extract` ladders, no `regexp_*` (banned; petition the user)
- base layers keep every row and column; `array_agg(x) AS xs, len(xs) AS n`, not `COUNT(*)`
- one layer at a time; CTEs, not subqueries inside table-function arguments; start at
  `LIMIT 1` / `WHERE name IN (…)` and widen
- every function call carries a comment listing all its parameters and defaults
- cast with the extension's type (`::HTML`, `::JSON`) and use its functions; no string surgery
- more than one statement → it is an artifact (Step 5), not a longer `-c` string

## Step 4 — Estimate result size

Session mode — sizes from the server:

```sql
FROM dev.query($$SELECT table_name, estimated_size, column_count FROM duckdb_tables() WHERE table_name IN ('<t1>', '<t2>')$$);
```

Ad-hoc file mode — probe in a sandbox:

```bash
duckdb :memory: -csv -c "
SET allowed_paths=['FILE_PATH'];
SET enable_external_access=false;
SET allow_persistent_secrets=false;
SET lock_configuration=true;
SELECT count() AS row_count FROM 'FILE_PATH';
"
```

- Bounded by `LIMIT`, `count()` or an aggregation → proceed.
- Source **>1M rows** with no bound → *"This would return a very large result set; I'd
  recommend `LIMIT 1000` or an aggregation."* Ask before running as-is.
- **>10 GB** → add *"This table is over 10 GB — the query may take a while."*
- Prefer **landing** a big result as a table on dev (`CREATE OR REPLACE TABLE … AS` inside
  `dev.query`) and reading back a slice: SQL-and-join beats stdout.

Skip for intrinsically bounded statements (`DESCRIBE`, `SUMMARIZE`, aggregations).

## Step 5 — Execute

**One statement** — session mode. Two shapes; pick by what it touches:

| Statement | Shape |
|---|---|
| one dev table, read only, no join | `SELECT … FROM dev.<table> …` client-side is fine |
| joins, aggregates over dev tables, server table functions, `CREATE`/`INSERT` on dev, TEMP tables, `SET VARIABLE`, macros defined on dev | `FROM dev.query($$ … $$)` |

A client-side join of two dev tables fails with "Multiple streaming scans … not currently
supported" — that is the signal to push it into `dev.query`. `SET`, `INSTALL`, `LOAD`, `PRAGMA`
against dev are refused ("the configuration has been locked"); do not try. Use a heredoc for
anything multi-line; inside `$$…$$` nothing needs escaping (use `$q$…$q$` if the SQL itself
contains `$$`):

```bash
QUACK_TOKEN="$(cat ~/.duck/token)" duckdb :memory: -csv <<'SQL'
LOAD quack;
ATTACH 'quack:localhost:9494' AS dev (TYPE quack, TOKEN getenv('QUACK_TOKEN'));
FROM dev.query($$
<QUERY>
$$);
SQL
```

**An artifact** — more than one statement, or anything the human should be able to edit and
re-run. Write `<name>.sql` with the head from `/duckdb-skills:duck` `references/head.sql`,
one table per statement, raw first, verification queries as trailing comments, `--#` lines
left in place. Run it by path (`-f` keeps the rc floor):

```bash
QUACK_TOKEN="$(cat ~/.duck/token)" duckdb :memory: -f <name>.sql
```

Where the artifact lives: next to the work it belongs to (a project's `queries/`, a
`sources/`, the scratchpad for a throwaway). There is no state directory.
If the human works in a console (`claudes-console`), the artifact *is* the console file: stage
it there, commit the round, execute by path, read the diff back.

**Ad-hoc file mode** (sandboxed — only the referenced files are reachable):

```bash
duckdb :memory: -csv <<'SQL'
SET allowed_paths=['FILE_PATH'];
SET enable_external_access=false;
SET allow_persistent_secrets=false;
SET lock_configuration=true;
<QUERY>;
SQL
```

Multiple files → list them all in `allowed_paths`.

## Step 6 — Handle errors

- **Syntax error**: show it, propose the corrected statement, re-run.
- **"Multiple streaming scans…"**: wrap the statement in `dev.query($$…$$)`.
- **Table not found**: list with `dev.query($$FROM duckdb_tables()$$)`; the client-side
  catalog is empty for a quack attach, so never conclude "missing" from a client-side
  `duckdb_tables()`.
- **"Authorization failed"**: the read-only door (9495) with a non-SELECT; use `dev` (9494) if
  the write is intended, otherwise fix the statement.
- **Missing extension on the client**: `/duckdb-skills:install-duckdb <ext>`. Missing on the
  **server**: it goes in `setup.sql`; report, do not `INSTALL` through dev.
- **Persistent or unclear DuckDB error**: `/duckdb-skills:duckdb-docs <error keywords>`.

## Step 7 — Present results

Show the output. Over 100 rows: note the truncation and suggest `LIMIT`, or land it as a
table and read back a slice. For natural-language questions add a brief interpretation, and
always show the SQL you ran — the user reads SQL fluently and will correct it.

---

## DuckDB Friendly SQL Reference

When generating SQL, prefer these idiomatic DuckDB constructs:

### Compact clauses
- **FROM-first**: `FROM table WHERE x > 10` (implicit `SELECT *`)
- **GROUP BY ALL**: auto-groups by all non-aggregate columns
- **ORDER BY ALL**: orders by all columns for deterministic results
- **SELECT * EXCLUDE (col1, col2)**: drop columns from wildcard
- **SELECT * REPLACE (expr AS col)**: transform a column in-place
- **UNION ALL BY NAME**: combine tables with different column orders
- **Percentage LIMIT**: `LIMIT 10%` returns a percentage of rows
- **Prefix aliases**: `SELECT x: 42` instead of `SELECT 42 AS x`
- **Trailing commas** allowed in SELECT lists

### Query features
- **count()**: no need for `count(*)` — but in base layers prefer `array_agg` + `len`
- **Reusable aliases**: use column aliases in WHERE / GROUP BY / HAVING
- **Lateral column aliases**: `SELECT i+1 AS j, j+2 AS k`
- **COLUMNS(*)**: apply expressions across columns; supports EXCLUDE, REPLACE, lambdas
- **FILTER clause**: `count() FILTER (WHERE x > 10)` for conditional aggregation
- **GROUPING SETS / CUBE / ROLLUP**: advanced multi-level aggregation
- **Top-N per group**: `max(col, 3)` returns top 3 as a list; also `arg_max(arg, val, n)`, `min_by(arg, val, n)`
- **QUALIFY**: filter on window results — the `_latest` snapshot idiom
- **DESCRIBE table_name**: schema summary; **SUMMARIZE table_name**: statistical profile
- **PIVOT / UNPIVOT**: reshape between wide and long formats
- **SET VARIABLE x = expr**: SQL-level variables, `getvariable('x')` — how a previous stage's list reaches a table-function argument

### Data import
- **Direct file queries**: `FROM 'file.csv'`, `FROM 'data.parquet'`
- **Globbing**: `FROM 'data/part-*.parquet'`; hive partitions are read as columns
- **Auto-detection**: CSV headers and schemas are inferred automatically

### Expressions and types
- **Dot operator chaining**: `'hello'.upper()` or `col.trim().lower()`
- **List comprehensions**: `[x*2 FOR x IN list_col]`
- **List/string slicing**: `col[1:3]`, negative indexing `col[-1]` (not for structural enumeration)
- **STRUCT.* notation**: `SELECT s.* FROM (SELECT {'a': 1, 'b': 2} AS s)`
- **Square bracket lists**: `[1, 2, 3]`
- **format()**: `format('{}->{}', a, b)` — not `||` chains

### Joins
- **ASOF joins**: approximate matching on ordered data (e.g. timestamps)
- **POSITIONAL joins**: match rows by position, not keys
- **LATERAL joins**: `FROM seeds CROSS JOIN LATERAL f(seeds.col)` — always correlated

### Data modification
- **CREATE OR REPLACE TABLE**: no need for `DROP TABLE IF EXISTS` first
- **CREATE TABLE ... AS SELECT (CTAS)**: raw first, one table per statement
- **INSERT INTO ... BY NAME**: match columns by name, not position
- **INSERT OR IGNORE INTO / INSERT OR REPLACE INTO**: upsert patterns

---
name: asset-factory
description: "Build a DuckDB pipeline the way Meta's Dataswarm does — DuckDBOperator(dep_list, sql, create, partition) creates its table and INSERT OVERWRITEs the partition; DuckDBWaitForPartitionOperator / DuckDBWaitForTableOperator are the dependencies; run() executes the dep_list first on one Duck. Use when writing a DAG, a snapshot-to-lake job, an operator, or anything that says DuckDBOperator, WaitFor, dep_list, create, partition, pre_sql/post_sql, <TABLE:x>, <DATEID>, <LATEST_DS:x>, to_lake, pg_attach, or 'land this table in the lake'. Read /duckstack:duck first; its SQL rules bind every sql an operator runs."
---

# asset-factory — Dataswarm operators on DuckDB

Straight from Meta's own description of Dataswarm
([Analytics at Meta](https://medium.com/@AnalyticsAtMeta/data-engineering-at-meta-high-level-overview-of-the-internal-tech-stack-a200460a44fe)):
a pipeline is operators; a wait operator blocks until an upstream partition lands; each query
operator names its dependencies in `dep_list`, the table it fills in `create`, and the
partition it writes in `partition`. **The author never writes a CREATE TABLE** — the operator
does. The write is `INSERT OVERWRITE PARTITION`, so rerunning a day is idempotent.

The operators **do not know what a query is for**: "the person using it could be running the
query that steals all the PII, or the query that makes the safe table for everybody. You don't
know, you don't care. The operators are just pure operators."

Library: `lib/duckstack` (`uv run --directory lib …`). `operators.py` builds operators,
`ducks.py` runs them, `mcp.py` exposes one DuckDBOperator as MCP tools.

## The shape

```python
from duckstack import DuckDBOperator, DuckDBWaitForPartitionOperator, Duck, Quack, run

# wait for today's partition to land on my_data_source
wait_for_my_data_source = DuckDBWaitForPartitionOperator(
    table="my_data_source", partition="ds=<DATEID>",
)
my_operator1 = DuckDBOperator(
    dep_list=[wait_for_my_data_source],
    sql="""
      SELECT /* some business logic */
      FROM <TABLE:my_data_source>
      WHERE ds = '<DATEID>'
    """,
    create="my_staging_table",
    partition={"ds": "<DATEID>"},
)
my_operator2 = DuckDBOperator(
    dep_list=[my_operator1],
    sql="SELECT … FROM <TABLE:my_staging_table> WHERE ds = '<DATEID>'",
    create="my_table",
    partition={"ds": "<DATEID>"},
)
run(my_operator2, "2026-09-22", Duck())   # the wait, then operator1, then operator2
```

A call site is `dep_list`, `sql`, `create`, `partition` — nothing else. Plumbing a caller
would otherwise spell out (`ATTACH IF NOT EXISTS`, `COPY … PARTITION_BY`) is a flag.

| Operator | What it does |
|---|---|
| `DuckDBWaitForPartitionOperator(table, partition="ds=<DATEID>")` | fails until that partition (`"ds=<DATEID>/country=US"` too) has rows |
| `DuckDBWaitForTableOperator(table)` | fails until the table exists |
| `DuckDBOperator(sql, create, dep_list, partition, …)` | below |

| `DuckDBOperator` argument | What it emits |
|---|---|
| `sql` | the query; reads `FROM <TABLE:x>`, filters `WHERE ds = '<DATEID>'` or `'<LATEST_DS:x>'` |
| `create` | the table's name; the operator writes `CREATE TABLE IF NOT EXISTS <TABLE:create> AS … LIMIT 0` |
| `partition` | `{"ds": "<DATEID>"}` by default; every key is the operator's — a column of that name in `sql` is replaced, never duplicated. `ds` is a string, as in Hive |
| `namespace` | the DuckDB schema the operator writes and resolves `<TABLE:x>` in (default `stg`) |
| `mode` | `overwrite` (default: DELETE the partition + `INSERT BY NAME`) · `replace` · `insert`. No key-based modes: DuckLake has no primary keys or UNIQUE constraints (docs p. 101); its upsert is `MERGE INTO` |
| `to_lake` | the partition → `<lake>/<create>/ds=<ds>/part0.parquet`, `OVERWRITE_OR_IGNORE`, idempotent |
| `pg_attach` | Postgres attached `READ_ONLY`; `sql` runs *in* Postgres via `postgres_query`, its `<TABLE:x>` left bare; `DETACH` after |
| `pre_sql` / `post_sql` | INSTALL/LOAD before, exports after |
| `fmt` | each key is a `{placeholder}` in all three bodies |

## Macros

- `<TABLE:x>` → `"x"` in production, `"test_x"` anywhere else — unquoted in the SQL, and the
  operator's own `create` table follows it too.
- `'<DATEID>'` → the partition being built, inside the author's quotes.
- `'<LATEST_DS:x>'` → the newest `ds` that table holds. `run()` asks the database on the same
  connection before shipping — never computed in Python — and refuses when the table is empty.

Any other date is DuckDB SQL: `DATE '<DATEID>' - 3`.

## Execution

`run(op, ds, duck, env)` walks `dep_list` depth-first on **one** Duck — each operator once, a
failing wait stops everything downstream — and returns `(name, bundle, receipt)` per
operator, in order. `Duck()` is a local DuckDB and the default; `Quack(uri, token_file)` ships
each bundle in one `quack_query`. The bundle's last statement is the table's own
`duckdb_tables()` row. `render(op, ds, env)` is the exact text that ships.

## One family per system

`DuckDB*` operators know DuckDB and nothing else. Postgres attachment belongs to a Postgres
family; S3, GCP, BigQuery transfers to theirs. `pg_attach` sits here until that family exists.

## What execution caught that reading did not

- A query reading an upstream partitioned table brings its `ds`; prepending another fails
  with "Duplicate column name". Partition columns are replaced via `COLUMNS(c -> …)`.
- DuckLake supports no indexes, primary keys or UNIQUE constraints (`~/Documents/ducklake-docs.pdf`
  pp. 48, 57, 101), so there is no `ON CONFLICT` mode. Upserts there are `MERGE INTO`.
- `COPY … PARTITION_BY` creates one directory level, never the lake root; `run` creates it.
- `<TABLE:x>` inside a `$pg$…$pg$` body must be bare — Postgres has no `test_` tables.

## Evidence

`uv run --directory lib pytest` (20 tests, real local DuckDB): overwrite rewrites its own day
and keeps the others; writes are BY NAME; replace and insert pinned; partition keys are the
operator's and land as hive directories; output is `test_`-prefixed off prod, bare in prod;
waits fail until the table / day lands, then the downstream runs; `dep_list` runs first and a
shared dep once; `<LATEST_DS:x>` picks the newest day and refuses an empty table; pre/post
sql order; lake rerun overwrites; receipt; `pg_attach` rendering and DSN redaction; both MCP
tools over stdio. Breaking deps, waits, DELETE-before-INSERT, BY NAME, OVERWRITE_OR_IGNORE,
`<LATEST_DS>` or the receipt filter each fails a test. Gates: `ruff`, strict `mypy`.

---
name: asset-factory
description: "Build a DuckDB pipeline the Dataswarm way — operators wired by deps: DuckDBWaitForTableOperator / DuckDBWaitForPartitionsOperator are the dependencies, DuckDBCreateTable creates its ds-partitioned table and INSERT OVERWRITEs that day's partition, and run() executes deps first on one Duck. Use when writing a DAG, a snapshot-to-lake job, an operator, or anything that says DuckDBCreateTable, WaitFor, deps, partition, pre_sql/post_sql, <TABLE:x>, <DATEID>, to_lake, pg_attach, or 'land this table in the lake'. Read /duckstack:duck first; its SQL rules bind every body an operator writes."
---

# asset-factory — operators, the Dataswarm way

Every node is an operator, and dependencies are operators too. A wait operator fails until
its upstream table or partition has landed; `deps=[...]` wires it in front of the operator
that needs it. The main operator creates its table if missing and **overwrites this run's
`ds` partition** — Presto's `INSERT OVERWRITE PARTITION` — so rerunning any day is idempotent.

The operators **do not know what a query is for**: "the person using it could be running the
query that steals all the PII, or the query that makes the safe table for everybody. You don't
know, you don't care. The operators are just pure operators."

Library: `lib/duckstack` (`uv run --directory lib …`). `operators.py` builds operators,
`ducks.py` runs them, `mcp.py` exposes one operator as MCP tools.

## The shape

```python
from duckstack import (DuckDBCreateTable, DuckDBWaitForPartitionsOperator, Duck, Quack, run)

wait_orders = DuckDBWaitForPartitionsOperator("orders")             # ds=<DATEID> has rows
daily = DuckDBCreateTable(
    name="orders_daily", deps=[wait_orders], to_lake=True,
    sql="SELECT id, sum(amt) AS amt FROM stg.<TABLE:orders> WHERE ds = DATE '<DATEID>' GROUP BY id",
)
run(daily, "2026-09-22", Duck())      # wait_orders, then orders_daily; or Quack() for the server
```

A call site is `name`, `group`, `deps`, and SQL — nothing else. Plumbing a caller would
otherwise spell out (`ATTACH IF NOT EXISTS`, `COPY … PARTITION_BY`) is a flag on the operator.

| Operator | What it does |
|---|---|
| `DuckDBWaitForTableOperator(table, group)` | fails until `group.<TABLE:table>` exists |
| `DuckDBWaitForPartitionsOperator(table, partitions=["ds=<DATEID>"], group)` | fails until each partition (`"ds=<DATEID>/country=US"`) has rows |
| `DuckDBCreateTable(name, sql, deps, …)` | `group.<TABLE:name>` from `sql`, as below |

| `DuckDBCreateTable` argument | What it emits |
|---|---|
| `sql` | the body; the date partition is filled from `<DATEID>` — **never by the query** (an incoming `ds` is replaced, not duplicated) |
| `partition` | `["ds"]` by default. The first is the run's date; any others (`country`) are the query's own columns |
| `schema` | `CREATE TABLE IF NOT EXISTS … (ds DATE, <schema>)`; declare one when a key must exist. Omit it and the table is created empty from the query |
| `mode` | `overwrite` (default: DELETE this `ds` + `INSERT BY NAME`) · `replace` · `insert` · `insert_or_ignore` · `insert_or_replace` |
| `to_lake` | this run's partition → `<lake>/<name>/ds=<ds>/part0.parquet`, `OVERWRITE_OR_IGNORE`, idempotent |
| `pg_attach` | Postgres attached `READ_ONLY` under an alias the query never sees; the body runs *in* Postgres via `postgres_query`, its `<TABLE:x>` left bare; `DETACH` after |
| `pre_sql` / `post_sql` | the escape hatch: INSTALL/LOAD before, exports after |
| `fmt` | each key is a `{placeholder}` in all three bodies |

## Macros — two, and only two

- `<TABLE:x>` → `"x"` in production, `"test_x"` anywhere else — the operator's own output
  table included. Qualify the group yourself: `stg.<TABLE:orders>`.
- `<DATEID>` → the partition date handed in, inside the caller's own quotes: `DATE '<DATEID>'`.

Nothing else is computed in Python. Three days back is `DATE '<DATEID>' - 3`; the latest
partition of a table is a read of DuckLake's own metadata.

## Execution

`run(op, ds, duck, env)` walks `deps` depth-first on **one** Duck — each operator once, a
failing wait stops everything downstream — and returns `(name, bundle, receipt)` per
operator, in the order they ran. Each operator ships in one call:

- `Duck()` — a local DuckDB, the default; nothing to install or serve.
- `Quack(uri="quack:localhost:9494", token_file="~/.duck/token")` — the whole bundle in one
  `quack_query`; the server holds the session between statements.

The bundle's last statement is the table's own `duckdb_tables()` row — the receipt.
`render(op, ds, env)` is the exact text that ships; read it when a run fails. Per-row fan-out
belongs *inside* an operator's SQL and is `/duckstack:self-dispatch`.

## One family per system

`DuckDB*` operators know DuckDB and nothing else. Postgres attachment belongs to a Postgres
family; S3, GCP, BigQuery transfers to theirs. `pg_attach` sits here today and migrates out
when the Postgres family exists.

## What execution caught that reading did not

- A downstream query reading an upstream table brings its `ds`; prepending another fails with
  "Duplicate column name". The operator replaces it with `COLUMNS(c -> c <> 'ds')`.
- `COPY … PARTITION_BY` creates one directory level, never the lake root, so `run` creates a
  local lake before shipping.
- A per-statement connection loses the table between statements. One connection per bundle.
- `<TABLE:x>` inside a `$pg$…$pg$` body must be unqualified and unprefixed — Postgres has no
  `test_` tables.

## Evidence

`uv run --directory lib pytest` — on a real local DuckDB: overwrite rewrites its own day and
keeps the others; every other mode run twice with rows pinned; extra partition columns land
as hive directories; the output table is `test_`-prefixed off prod and bare in prod; waits
fail until the table / day lands and then let the downstream run; deps run first and a shared
dep once; pre/post sql order; lake rerun overwrites; receipt row; `pg_attach` rendering and
DSN redaction; both MCP tools over stdio. Mutations of deps, waits, BY NAME, OVERWRITE and the
receipt filter each fail a test. Gates: `ruff`, `ruff format`, strict `mypy`.

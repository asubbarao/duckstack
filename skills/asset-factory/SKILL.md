---
name: asset-factory
description: "Build a DuckDB pipeline step the Dataswarm way — one pure asset factory, DuckDBCreateTable, that turns a SELECT into that run's table and returns a Step that ships to any Duck in one call. Use when writing a DAG, a snapshot-to-lake job, an operator, or anything that says DuckDBCreateTable, asset factory, Step, pre_sql/post_sql, <TABLE:x>, <DATEID>, to_lake, pg_attach, Dagster adapter, or 'land this table in the lake'. Read /duckstack:duck first; its SQL rules bind every body a step writes."
---

# asset-factory — the factory is a gun

A step is a SELECT. One factory wraps it as that run's table. The factory **does not know
what the step is for**: "the person using it could be running the query that steals all the
PII, or the query that makes the safe table for everybody. You don't know, you don't care.
The operators are just pure operators." That sentence decides every design question below.

Source of truth, read it before writing a step:
`inframe/internal/duckdb/warehouse/operators.py` (branch `codex/consolidator`, and the
`INF-1387` draft to `staging`). Everything here was verified by executing it on 2026-09-23.

## The shape

```python
from operators import DuckDBCreateTable, Duck, Quack, run, render

catalog = DuckDBCreateTable(name="pg_catalog_cols", group="raw", pg_attach=True, sql="...")
snapshots = [
    DuckDBCreateTable(name=t, group="lake", deps=[catalog], pg_attach=True, to_lake=True,
                      sql=f"SELECT * FROM <TABLE:{t}>")
    for t in table_names
]
bundle, receipt = run(snapshots[0], "2026-09-22", Quack())   # or Duck() for a laptop
```

A call site is `name`, `group`, `deps`, and SQL — nothing else. Plumbing a caller would
otherwise spell out at every step (`ATTACH IF NOT EXISTS`, `COPY … PARTITION_BY`) is a flag
on the factory: optional, and automatic when asked for. Never hand-write it in a DAG.

| Argument | What the factory emits |
|---|---|
| `sql` | the body; `dt` is prepended from the run's partition — **never by the step** |
| `schema` | `CREATE TABLE IF NOT EXISTS … (dt DATE, <schema>)`; declare a key when an insert mode must honour one. Omit it and the table is created empty from the SELECT — DuckDB infers, do not port Hive's declared-DDL habit |
| `mode` | `replace` (default) · `insert` · `insert_or_ignore` · `insert_or_replace` · `upsert` = DELETE this run's `dt` + `INSERT BY NAME`, no key, concurrent partitions can't collide. All plain writes: the table exists first |
| `fmt` | a config row; each key is a `{placeholder}` in all three bodies. Replace loop, never `.format` — SQL has braces of its own |
| `pg_attach` | Postgres attached `READ_ONLY` under a per-step alias the step never sees; the body runs *in* Postgres via `postgres_query`; `DETACH` after. `test_` prefix defaults off — a source has no test tables to be kept away from |
| `to_lake` | `COPY … PARTITION_BY (dt) OVERWRITE_OR_IGNORE` → `<lake>/<name>/dt=<ds>/part0.parquet`, one file per day, idempotent |
| `pre_sql` / `post_sql` | the escape hatch: INSTALL/LOAD before, anything that needs the table after |

## Macros — two, and only two

- `<TABLE:x>` → `"x"` in production, `"test_x"` anywhere else. Unqualified. Naming a table in
  a body is how the body declares it as a dependency.
- `<DATEID>` → the partition date the scheduler hands in, substituted as text inside the
  caller's own quotes: `DATE '<DATEID>'`.

Nothing else is computed in Python. Three days back is `DATE '<DATEID>' - 3`; the latest
partition of a table is a read of DuckLake's own metadata. "Not some Python string shit — it
came from the Hive metastore at Meta."

## Execution — ship the bundle, read the tail

`Step` is an ordered bundle of statements. It ships to a `Duck` **in one call**:

- `Duck()` — a local DuckDB, the default; nothing to install or serve.
- `Quack(uri="quack:localhost:9494", token_file="~/.duck/token")` — the whole bundle in one
  `quack_query`; the server holds the session between statements, nothing is left on the client.
  Verified: `quack_query` takes a multi-statement body and returns the last statement's rows
  (through the `dev` MCP door, whose wrapper *is* one `quack_query`, and from a local client).

The bundle's last statement is the table's own `duckdb_tables()` row — the receipt. Its
`rows_estimated` is an estimate: after `upsert` it counts deleted rows until checkpoint.
`render(step, ds)` is the exact text that shipped; read it, not the DAG, when a run fails.

Per-row fan-out belongs *inside* a step's SQL and is `/duckstack:self-dispatch` — the factory
neither knows nor cares. A scheduler is an adapter at the edge: `dagster_adapter.py` is the
only file that imports Dagster, and it hands a Step nothing but the partition date.

## One factory family per system

`DuckDB*` factories know DuckDB and nothing else. Postgres attachment is a Postgres family;
S3, GCP, BigQuery transfers are theirs. `pg_attach` sits on the DuckDB factory today and is
the thing that migrates out when the Postgres family exists. Airflow-provider in shape,
Dataswarm in spirit.

## What execution caught that reading did not

- A schema-only `_empty.parquet` "so a reader binds on an empty day" **cannot work as a plain
  COPY**: single-file `COPY` creates no directories; only `PARTITION_BY` does, and it writes
  nothing for zero rows. The reader view anchors its own schema.
- A per-statement connection loses the table between statements. One connection per bundle.
- `<TABLE:x>` inside a `$pg$…$pg$` body must be unqualified — a `lake.` prefix leaks into
  Postgres, where no such schema exists.
- `COPY … PARTITION_BY` creates one directory level, never the lake root, so `run` creates a
  local lake before shipping.

## Evidence

`uv run --directory lib pytest` — every mode executed twice on a local DuckDB with the result
rows pinned (replace keeps the latest, insert appends, insert_or_ignore keeps the first value
for a key, insert_or_replace takes the new one, upsert rewrites its own partition and keeps
others), pre_sql before and post_sql after the write, the lake landing `dt=<ds>/part0.parquet`
and reading back, the receipt row, `<TABLE:x>` / `<DATEID>` / `{placeholder}` resolution, the
`pg_attach` bundle with its DSN redacted, and the real MCP entrypoint over stdio.
Gates: `ruff`, `ruff format`, strict `mypy`.

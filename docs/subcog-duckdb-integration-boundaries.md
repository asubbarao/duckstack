# Subcog and DuckDB: integration boundaries

## Decision

Keep Subcog's existing Rust services and SQLite database as the authoritative memory system. Add DuckDB as a **read-only relational consumer** of that database where joins, inspection, or downstream publication need SQL. Do not introduce a DuckDB persistence backend, a second memory writer, or a DuckLake requirement for ordinary capture and recall.

The boundaries are different granularities, not competing implementations:

| Surface | Owns | Does not own |
| --- | --- | --- |
| Subcog service + MCP | Capture, update, delete, native recall, indexing, permissions, and agent-facing callable operations | Analytical SQL or lake publication |
| Agent skill | When and why to call Subcog, what to retain, and how to interpret results | Storage, executable SQL, or a second tool protocol |
| DuckDB SQL file/view/macro | Relational read model, joins, repeatable transformations, and parameterized SQL expressions | Memory lifecycle, scheduling, or authorization by itself |
| Thin Python library/operator | Where a scheduler needs Python: construct steps, resolve run context and Dataswarm-style tokens, submit SQL to the *selected* service, and return receipts | Business transformations that can remain inline SQL, a second database owner, or implicit service selection |
| Scheduler (later) | When a partition runs, dependencies, retries, and backfills | The SQL transformation or Subcog's capture lifecycle |

Subcog already exposes capture and recall through its [MCP server](../mcp/README.md) and keeps SQLite authoritative; its [service architecture](README.md) separates persistence, FTS index, and vector search. A DuckDB query over SQLite is **not** equivalent to Subcog recall: it does not reproduce FTS/vector ranking, scoping, or service-side policy.

## Smallest useful integration

1. Continue to invoke `subcog_capture`, `subcog_recall`, and related operations through Subcog MCP (or its CLI when explicitly chosen). Do not write its tables through DuckDB.
2. In the explicitly selected DuckDB process/service, attach the actual Subcog SQLite file read-only and expose only the narrowly needed relational view. The path is an input, not a hard-coded assumption:

   ```sql
   INSTALL sqlite;
   LOAD sqlite;
   ATTACH '/absolute/path/to/selected/subcog.sqlite' AS subcog_sqlite
     (TYPE sqlite, READ_ONLY);
   -- Inspect the selected file's schema before defining a stable projection.
   SELECT table_schema, table_name
   FROM information_schema.tables
   WHERE table_catalog = 'subcog_sqlite';
   ```

3. Put the useful transformation in one self-contained SQL file. Introduce a DuckDB macro only after an expression or parameterized relation is repeated; a macro is not a pipeline or a tool. Preserve raw fields in the base read and build any narrower projection above it.
4. If daily history is needed, publish a dated *derived snapshot* to the chosen lake with a bounded, idempotent partition write. DuckLake may catalog that history later; it is not Subcog's source of truth, a replacement for SQLite, or necessary for a live read.

SQLite's affinity types can differ from DuckDB's enforced types. Validate the selected file's schema and representative rows before treating a view as stable; do not globally force `sqlite_all_varchar` without a documented reason, and do not infer that `ATTACH READ_ONLY` supplies MCP authorization. SQLite locking/WAL and service boundaries still apply. The local process must attach the **selected** Quack/SQLite target explicitly; an ephemeral `duckdb :memory:` client is not the persistent owner.

## Daily operators: SQL first, scheduler later

For the daily-use case, keep the transform visible as inline SQL with explicit partition markers, for example:

```sql
-- Conceptual body supplied to the operator; not a runnable Subcog migration.
SELECT DATE '<DATEID>' AS dt, *
FROM subcog_sqlite.main.memories;
```

`<DATEID>` is the **run's partition**, not wall-clock `today`. The prototype's `<TABLE:name>` marker is for a *destination* (for example, `INSERT INTO <TABLE:subcog_memories> ...`), resolving to a safe test namespace on non-production runs; it is not the attached SQLite source. Resolve markers at the execution boundary, record the expanded SQL in a run receipt, and reject unknown markers. Keep the SQL body in the asset definition/file; do not hide joins and business rules inside a Python factory.

There is already an InFrame proof of concept (`internal/duckdb/warehouse/operators.py`) with scheduler-free `Step` objects, `<TABLE:...>` / `<DATEID>` resolution, and `run(step, partition)` against a chosen Quack service. Its Dagster adapter (`internal/duckdb/warehouse/dagster_adapter.py`) supplies daily partitions and dependencies. That substrate is explicitly marked `poc` in its `CONTEXT.md`: it is evidence for a possible boundary, not a production dependency or a reason to import the library into Subcog. A future adapter should reuse or narrow this boundary only when a real scheduled asset warrants it. Until then, a SQL file run explicitly against the chosen DuckDB service is enough.

## Acceptance boundary

- Native Subcog capture/recall results and SQLite/index ownership do not change.
- DuckDB attachment is read-only, points to the selected SQLite file, and is tested on its real schema and data types.
- Any lake output is derived and date-partitioned; rerunning one day changes only that day's partition.
- The selected execution service, effective partition, expanded SQL, and row/operation receipt are observable; no implicit switch between local `:memory:`, Quack, and MCP paths.
- No new MCP tool, skill, macro, Python operator, or scheduler is added without a concrete consumer that needs that granularity.

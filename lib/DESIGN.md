# Declarative table factories

Duckstack's factory compiles a table declaration into one checked SQL transaction.
The separate Dagster adapter turns declarations into assets. Pipeline authors supply
dependencies, database declarations, schemas and inline SQL; factory implementation
owns connections and execution. No pipeline-authored decorators, context managers,
subprocesses or separate SQL templates are needed.

## Supported contract

`DuckDBCreateTableWithSchemaOperator` and
`PostgresCreateTableWithSchemaOperator` share a `TableOperator` declaration. `schema`
is an ordered mapping of output column names to trusted, dialect-specific SQL type
declarations. Every declared non-partition column must exist in the SELECT. Values
are inserted into a typed temporary table before publication. Extra query columns
are ignored; declared columns are selected by name, not source position. Database
casts apply: this is a typed output contract, not an exact input-type equality test.

DuckDB declarations accept an optional `catalog` naming an already attached catalog,
including DuckLake. With `catalog="lake"` and `namespace="analytics"`, the factory
creates `"lake"."analytics"` and publishes to `"lake"."analytics"."<create>"`.
All target writes are qualified; source SQL and the typed temporary candidate keep
their existing resolution semantics. The caller attaches/configures the lake on
the executor before execution. The factory does not attach catalogs or choose
metadata/data paths. PostgreSQL declarations retain schema/table targets and do not
accept cross-database catalog targeting.

Without `partition`, each execution replaces all rows while retaining the table.
With `partition`, only matching rows are replaced. Partition columns are declared in
`schema` and their values are owned by the factory. `"<DATEID>"` receives the complete
scheduler partition key, including an hour if applicable. Inline SQL can use the
complete literal `'<DATEID>'`; it is safely rendered as one value. Other arbitrary
SQL interpolation is not provided.

`.DQCheck(type=col.NOTNULL, column="id")` and
`.DQCheck(name="unique_id", sql="SELECT id FROM <TABLE> GROUP BY id HAVING sum(1) > 1")`
return a new declaration. `<TABLE>` refers to this execution's typed candidate,
never the existing target. A custom check passes when its query returns no rows.
Empty output is valid unless a check explicitly rejects it. Checks abort the
transaction before target replacement, retaining the previous published rows.
Failure messages identify the check; no potentially sensitive violating rows are
automatically copied into orchestration logs.

Existing target schemas are not automatically migrated. An incompatible target
write fails and rolls back. SQL is trusted author code; these declarations are not
a sandbox for untrusted SQL. The factory's atomicity applies to transactional
database tables, not external effects hidden in user SQL. There is no exactly-once
claim for network timeouts; callers must reconcile an uncertain outcome before retry.

## Connections and orchestration

`ConnectToDatabase(db=..., type="local" | "quack" | "quackapi" | "postgres")`
is lazy. `local` retains a DuckDB connection; `quack` reads the configured token file
and sends one bundle; `quackapi` POSTs JSON to `<db>/sql`; `postgres` uses the optional
psycopg extra. A caller-supplied object implementing `execute(sql)` can replace any
of these. Operators can carry their own connection or receive a default at execution.
No named Dagster resource is mandatory. Connection strings should come from runtime
configuration, not committed credentials.

`execute_operator` executes one operator only. `dagster_adapter.assets` generates
one asset per declaration, preserving dependency keys, partition definitions and
retry policies. Attached checks become blocking Dagster check specs and emitted
results. The checks execute before publication inside the asset, so failed checks
also fail the asset and prevent downstream materialization. Dagster owns DAG
validation, scheduling, selection, retries and backfills; Duckstack has no new
scheduler. The adapter never calls the legacy recursive `run()`.

The adapter's default in-memory DuckDB is for in-process execution. For multiprocess
Dagster, configure a shared remote database. Each operator's fully qualified
`(namespace, create)` is its asset key; supplying a DuckDB catalog adds it as the
first component: `(catalog, namespace, create)`. Dependency and check keys use the
same identity, so identically named tables in distinct catalogs remain distinct.
Give outputs unique keys within one graph.
The first version supports a single partition key passed intact. Mapping multiple
partition dimensions into independent SQL columns is not yet provided.

The core imports neither Dagster nor psycopg. Install `[dagster]` for the adapter
and `[postgres]` for PostgreSQL. A future Airflow/Prefect adapter can consume the
same declarations and executor protocol without changing pipeline business SQL.
No additional adapters are implemented here.

## Scope and compatibility

The earlier `DuckDBOperator`, `Duck`, `Quack`, `run`, and MCP tools remain compatible.
The new checked factories are an additive API and do not retrofit legacy lake
exports. Signed agent-log files and `to_lake` exports remain separate mechanisms.
No new publication system, parser, catalog discovery engine or service is added.

The examples in `examples/` simplify the business-profile sketch's shape. They do
not execute its schema resets, copy its full domain model or connect to its data.

## Acceptance tests

Tests exercise changed/empty partition reruns, typed staging, name-based writes,
NOT NULL and duplicate violations preserving old data, quotation, optional imports,
actual Dagster checks/materialization/downstream blocking/retries/cycle validation,
and complete hourly keys. Isolated temporary DuckLake catalogs exercise typed
checks, partition overwrite, empty success, failed-check rollback, historical
version reads, and qualified writes without default-database publication.
PostgreSQL execution runs only when
`DUCKSTACK_TEST_POSTGRES_DSN` identifies a disposable test database. CI provisions
that database separately. Remote probes must use isolated names on the selected
existing service; no new server is required.

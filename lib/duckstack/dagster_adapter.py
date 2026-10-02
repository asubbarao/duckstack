"""Optional adapter. Dagster owns graph traversal, retries and partitions."""

from collections.abc import Iterator, Sequence
from typing import Any

import dagster as dg

from duckstack.connections import ConnectToDatabase, Executor
from duckstack.factory import TableOperator, execute_operator


def assets(
    operators: Sequence[TableOperator], *, database: Executor | None = None,
    partitions_def: dg.PartitionsDefinition[Any] | None = None,
    retry_policy: dg.RetryPolicy | None = None,
) -> list[dg.AssetsDefinition]:
    """Generate assets without requiring named resources or decorators in pipelines.

    Supply a persistent database for multiprocess execution. The implicit local
    connection is convenient for in-process use, not a shared-memory server.
    """
    default_database = database if database is not None else ConnectToDatabase()

    def make(op: TableOperator) -> dg.AssetsDefinition:
        key = dg.AssetKey(list(op.key))

        @dg.asset(
            key=key,
            deps=[dg.AssetKey(list(dep.key)) for dep in op.deps],
            partitions_def=partitions_def,
            retry_policy=retry_policy,
            check_specs=[dg.AssetCheckSpec(c.name, asset=key, blocking=True) for c in op.checks],
        )
        def compute(context: dg.AssetExecutionContext) -> Iterator[Any]:
            partition = context.partition_key if context.has_partition_key else None
            try:
                receipt = execute_operator(op, partition, database=default_database)
            except Exception as exc:
                for check in op.checks:
                    if f"DQCheck failed: {check.name}" in str(exc):
                        yield dg.AssetCheckResult(
                            passed=False, asset_key=key, check_name=check.name,
                            metadata={"partition": partition or "unpartitioned"},
                        )
                raise
            for check in op.checks:
                yield dg.AssetCheckResult(
                    passed=True, asset_key=key, check_name=check.name,
                    metadata={"partition": partition or "unpartitioned"},
                )
            yield dg.MaterializeResult(metadata={
                "database_dialect": op.dialect,
                "table": ".".join(op.key),
                "partition": partition or "unpartitioned",
                "receipt": str(receipt),
            })

        return compute

    return [make(op) for op in operators]


def definitions(
    operators: Sequence[TableOperator], *, database: Executor | None = None,
    partitions_def: dg.PartitionsDefinition[Any] | None = None,
    retry_policy: dg.RetryPolicy | None = None,
) -> dg.Definitions:
    return dg.Definitions(assets=assets(
        operators, database=database, partitions_def=partitions_def, retry_policy=retry_policy,
    ))

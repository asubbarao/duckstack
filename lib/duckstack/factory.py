"""Relational declarations, SQL compilation and checked publication; no orchestrator."""

from __future__ import annotations

from dataclasses import dataclass, replace
from datetime import date, datetime
from enum import Enum
from typing import Any, Literal
from uuid import uuid4

from duckstack.connections import ConnectToDatabase, Executor


def identifier(value: str) -> str:
    if not value or "\x00" in value:
        raise ValueError("An identifier must be nonempty and contain no NUL")
    return '"' + value.replace('"', '""') + '"'


def literal(value: Any) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, (str, date, datetime)):
        return "'" + str(value).replace("'", "''") + "'"
    raise TypeError(f"Unsupported partition value: {type(value).__name__}")


class col(Enum):
    NOTNULL = "not_null"


@dataclass(frozen=True)
class Check:
    name: str
    sql: str | None = None
    column: str | None = None


@dataclass(frozen=True)
class TableOperator:
    create: str
    sql: str
    schema: dict[str, str]
    namespace: str = "main"
    database: Executor | None = None
    deps: tuple[TableOperator, ...] = ()
    partition: dict[str, Any] | None = None
    dialect: Literal["duckdb", "postgres"] = "duckdb"
    checks: tuple[Check, ...] = ()
    catalog: str | None = None

    @property
    def key(self) -> tuple[str, ...]:
        if self.catalog is not None:
            return self.catalog, self.namespace, self.create
        return self.namespace, self.create

    def DQCheck(
        self,
        *,
        type: col | None = None,
        column: str | None = None,
        sql: str | None = None,
        name: str | None = None,
    ) -> TableOperator:
        """Attach a check. Custom SQL returns violating rows; zero rows passes."""
        if type == col.NOTNULL and column is not None and sql is None:
            if column not in self.schema:
                raise ValueError(f"Unknown check column: {column}")
            check = Check(name or f"{column}_not_null", column=column)
        elif type is None and column is None and sql is not None and name:
            check = Check(name, sql=sql)
        else:
            raise ValueError("Use type=col.NOTNULL, column=... or name=..., sql=...")
        if check.name in {c.name for c in self.checks}:
            raise ValueError(f"Duplicate check name: {check.name}")
        return replace(self, checks=(*self.checks, check))


def DuckDBCreateTableWithSchemaOperator(
    *,
    create: str,
    sql: str,
    schema: dict[str, str],
    namespace: str = "main",
    database: Executor | None = None,
    deps: tuple[TableOperator, ...] = (),
    partition: dict[str, Any] | None = None,
    catalog: str | None = None,
) -> TableOperator:
    return TableOperator(
        create, sql, schema, namespace, database, tuple(deps), partition, catalog=catalog
    )


def PostgresCreateTableWithSchemaOperator(
    *,
    create: str,
    sql: str,
    schema: dict[str, str],
    namespace: str = "public",
    database: Executor | None = None,
    deps: tuple[TableOperator, ...] = (),
    partition: dict[str, Any] | None = None,
) -> TableOperator:
    return TableOperator(
        create, sql, schema, namespace, database, tuple(deps), partition, "postgres"
    )


def _date(sql: str, partition_key: str | None) -> str:
    if "<DATEID>" not in sql:
        return sql
    if partition_key is None:
        raise ValueError("<DATEID> requires a partition key")
    sql = sql.replace("'<DATEID>'", literal(partition_key))
    if "<DATEID>" in sql:
        raise ValueError("Use '<DATEID>' as a complete SQL literal")
    return sql


def compile_operator(op: TableOperator, partition_key: str | None = None) -> str:
    """Build one transaction: typed staging, checks, replacement, commit, receipt.

    Check SQL reads <TABLE>, the candidate output for this invocation. Publication
    follows validation, so invalid candidates cannot replace a previous result.
    """
    if not op.schema:
        raise ValueError("schema must declare the output columns")
    for data_type in op.schema.values():
        if not data_type.strip() or ";" in data_type:
            raise ValueError("schema types must be single SQL type declarations")
    if op.partition is not None and not op.partition:
        raise ValueError("Use partition=None for full-table replacement")
    unknown = set(op.partition or {}) - set(op.schema)
    if unknown:
        raise ValueError(f"Partition columns missing from schema: {sorted(unknown)}")
    if op.catalog is not None and op.dialect != "duckdb":
        raise ValueError("catalog targets require a DuckDB operator")
    namespace = identifier(op.namespace)
    if op.catalog is not None:
        namespace = f"{identifier(op.catalog)}.{namespace}"
    target = f"{namespace}.{identifier(op.create)}"
    stage = identifier("duckstack_stage_" + uuid4().hex)
    definitions = ", ".join(f"{identifier(k)} {v}" for k, v in op.schema.items())
    columns = ", ".join(identifier(k) for k in op.schema)
    part = {k: partition_key if v == "<DATEID>" else v for k, v in (op.partition or {}).items()}
    if any(v == "<DATEID>" for v in (op.partition or {}).values()) and partition_key is None:
        raise ValueError("Partition <DATEID> requires a partition key")
    projection = ", ".join(
        f"{literal(part[k])} AS {identifier(k)}" if k in part else identifier(k) for k in op.schema
    )
    statements = [
        "BEGIN",
        f"CREATE SCHEMA IF NOT EXISTS {namespace}",
        f"CREATE TEMP TABLE {stage} ({definitions})",
        f"INSERT INTO {stage} ({columns}) SELECT {projection} "
        f"FROM ({_date(op.sql, partition_key)}) AS input",
    ]
    for check in op.checks:
        violations = (
            f"SELECT 1 FROM {stage} WHERE {identifier(check.column)} IS NULL"
            if check.column is not None
            else _date(check.sql or "", partition_key).replace("<TABLE>", stage)
        )
        if op.dialect == "duckdb":
            statements.append(
                f"SELECT CASE WHEN EXISTS ({violations}) "
                f"THEN error({literal('DQCheck failed: ' + check.name)}) ELSE 'pass' END"
            )
        else:
            tag = "$dq_" + uuid4().hex + "$"
            statements.append(
                f"DO {tag} BEGIN IF EXISTS ({violations}) THEN "
                f"RAISE EXCEPTION USING MESSAGE = {literal('DQCheck failed: ' + check.name)}; "
                f"END IF; END {tag}"
            )
    where = " AND ".join(
        f"{identifier(k)} IS NOT DISTINCT FROM {literal(v)}" for k, v in part.items()
    )
    statements += [
        f"CREATE TABLE IF NOT EXISTS {target} ({definitions})",
        f"DELETE FROM {target}" + (f" WHERE {where}" if where else ""),
        f"INSERT INTO {target} ({columns}) SELECT {columns} FROM {stage}",
        f"DROP TABLE {stage}",
        "COMMIT",
        f"SELECT {literal(op.namespace)} AS namespace, {literal(op.create)} AS table_name",
    ]
    return ";\n".join(statements)


def execute_operator(
    op: TableOperator,
    partition_key: str | None = None,
    *,
    database: Executor | None = None,
) -> list[tuple[Any, ...]]:
    """Execute only this declaration. Dependency scheduling belongs to the caller."""
    executor = op.database or database
    if executor is None:
        if op.dialect == "postgres":
            raise ValueError("PostgreSQL execution requires a connection")
        executor = ConnectToDatabase()
    if isinstance(executor, ConnectToDatabase):
        expected = "postgres" if op.dialect == "postgres" else "duckdb"
        actual = "postgres" if executor.type == "postgres" else "duckdb"
        if expected != actual:
            raise ValueError(f"{op.dialect} operator cannot use {executor.type} connection")
    return executor.execute(compile_operator(op, partition_key))

"""Duckstack operators for DuckDB, inspired by Meta's Dataswarm.

operators.py builds them; ducks.py runs them."""

from duckstack.ducks import Duck, Quack, run
from duckstack.connections import ConnectToDatabase, Executor
from duckstack.factory import (
    DuckDBCreateTableWithSchemaOperator,
    PostgresCreateTableWithSchemaOperator,
    TableOperator,
    col,
    compile_operator,
    execute_operator,
)
from duckstack.operators import (
    LOCAL,
    DuckDBOperator,
    DuckDBWaitForPartitionOperator,
    DuckDBWaitForTableOperator,
    Env,
    Operator,
    render,
    resolve,
)

__all__ = [
    "ConnectToDatabase",
    "Executor",
    "DuckDBCreateTableWithSchemaOperator",
    "PostgresCreateTableWithSchemaOperator",
    "TableOperator",
    "col",
    "compile_operator",
    "execute_operator",
    "LOCAL",
    "Duck",
    "DuckDBOperator",
    "DuckDBWaitForPartitionOperator",
    "DuckDBWaitForTableOperator",
    "Env",
    "Operator",
    "Quack",
    "render",
    "resolve",
    "run",
]

"""Duckstack operators for DuckDB, inspired by Meta's Dataswarm.

operators.py builds them; ducks.py runs them."""

from duckstack.connections import ConnectToDatabase, Executor
from duckstack.ducks import Duck, Quack, run
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
    "LOCAL",
    "ConnectToDatabase",
    "Duck",
    "DuckDBCreateTableWithSchemaOperator",
    "DuckDBOperator",
    "DuckDBWaitForPartitionOperator",
    "DuckDBWaitForTableOperator",
    "Env",
    "Executor",
    "Operator",
    "PostgresCreateTableWithSchemaOperator",
    "Quack",
    "TableOperator",
    "col",
    "compile_operator",
    "execute_operator",
    "render",
    "resolve",
    "run",
]

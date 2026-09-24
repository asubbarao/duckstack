"""Dataswarm-style operators for DuckDB. operators.py builds them; ducks.py runs them."""

from duckstack.ducks import Duck, Quack, run
from duckstack.operators import (
    LOCAL,
    DuckDBCreateTable,
    DuckDBWaitForPartitionsOperator,
    DuckDBWaitForTableOperator,
    Env,
    Operator,
    render,
    resolve,
)

__all__ = [
    "LOCAL",
    "Duck",
    "DuckDBCreateTable",
    "DuckDBWaitForPartitionsOperator",
    "DuckDBWaitForTableOperator",
    "Env",
    "Operator",
    "Quack",
    "render",
    "resolve",
    "run",
]

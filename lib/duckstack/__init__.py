"""Dataswarm-style operators for DuckDB. operators.py builds them; ducks.py runs them."""

from duckstack.ducks import Duck, Quack, run
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

"""Dataswarm-style asset factories for DuckDB. operators.py builds Steps; ducks.py runs them."""

from duckstack.ducks import Duck, Quack, run
from duckstack.operators import LOCAL, DuckDBCreateTable, Env, Step, render, resolve

__all__ = [
    "LOCAL",
    "Duck",
    "DuckDBCreateTable",
    "Env",
    "Quack",
    "Step",
    "render",
    "resolve",
    "run",
]

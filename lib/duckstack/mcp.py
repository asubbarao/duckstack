"""DuckDBCreateTable as MCP tools, over stdio.

Two tools and nothing else. `render_step` builds the operator and returns the exact bundle a
run would ship — read it before running it. `run_step` builds, ships and returns the bundle
beside its receipt. Every operator argument is a tool argument; the Env is three more. A tool
call is one operator, so deps belong to a Python DAG, not here.
"""

from __future__ import annotations

from typing import Any

from mcp.server.mcpserver import MCPServer

from duckstack import Duck, DuckDBCreateTable, Env, Operator, Quack, render, run

server = MCPServer("duckstack")


def _op(args: dict[str, Any]) -> Operator:
    keys = "name sql group schema partition mode pg_attach to_lake pre_sql post_sql fmt".split()
    return DuckDBCreateTable(**{k: args[k] for k in keys})


@server.tool()
def render_step(
    name: str,
    sql: str,
    ds: str,
    group: str = "stg",
    schema: str | None = None,
    partition: list[str] | None = None,
    mode: str = "overwrite",
    pg_attach: bool = False,
    to_lake: bool = False,
    pre_sql: str | None = None,
    post_sql: str | None = None,
    fmt: dict[str, str] | None = None,
    prod: bool = False,
    lake: str = "~/.duck/lake",
    pg_dsn: str = "",
) -> str:
    """The exact bundle a run would ship for one partition date — every macro and placeholder
    resolved. group.<TABLE:name> from sql, partitioned by partition (default ["ds"], filled
    from ds). mode is overwrite (INSERT OVERWRITE PARTITION, the default), replace, insert,
    insert_or_ignore or insert_or_replace; <TABLE:x> and <DATEID> are the only macros. Returns
    SQL, one statement per line, the last being the receipt."""
    bundle = render(_op(locals()), ds, Env(prod=prod, lake=lake, pg_dsn=pg_dsn))
    return bundle.replace(pg_dsn, "<pg_dsn>") if pg_dsn else bundle


@server.tool()
def run_step(
    name: str,
    sql: str,
    ds: str,
    group: str = "stg",
    schema: str | None = None,
    partition: list[str] | None = None,
    mode: str = "overwrite",
    pg_attach: bool = False,
    to_lake: bool = False,
    pre_sql: str | None = None,
    post_sql: str | None = None,
    fmt: dict[str, str] | None = None,
    prod: bool = False,
    lake: str = "~/.duck/lake",
    pg_dsn: str = "",
    duck: str = "local",
    database: str = ":memory:",
    quack_uri: str = "quack:localhost:9494",
    token_file: str = "~/.duck/token",
) -> dict[str, Any]:
    """Build, ship and receipt one operator for one partition date. duck is "local" (a DuckDB
    at `database`, the default) or "quack" (the whole bundle in one quack_query on the server at
    `quack_uri`). Returns {"bundle": the SQL that shipped, DSN redacted, "receipt": the last
    statement's rows — the table's own duckdb_tables() row}."""
    executor: Duck = Quack(quack_uri, token_file) if duck == "quack" else Duck(database)
    [(_, bundle, receipt)] = run(
        _op(locals()), ds, executor, Env(prod=prod, lake=lake, pg_dsn=pg_dsn)
    )
    return {
        "bundle": bundle.replace(pg_dsn, "<pg_dsn>") if pg_dsn else bundle,
        "receipt": [list(r) for r in receipt],
    }


def main() -> None:
    server.run(transport="stdio")


if __name__ == "__main__":
    main()

"""The asset factory as MCP tools, over stdio.

Two tools and nothing else. `render` builds a Step and returns the exact bundle a run would
ship — read it before running it. `run` builds, ships and returns the bundle beside its
receipt. Every factory argument is a tool argument; the Env is three arguments more. The
server itself knows nothing about what the SQL is for.
"""

from __future__ import annotations

from typing import Any

from mcp.server.mcpserver import MCPServer

from duckstack import Duck, DuckDBCreateTable, Env, Quack, render, run

server = MCPServer("duckstack")


def _step(
    name: str,
    sql: str,
    group: str,
    schema: str | None,
    mode: str,
    pg_attach: bool,
    to_lake: bool,
    pre_sql: str | None,
    post_sql: str | None,
    prefix: bool | None,
    fmt: dict[str, str] | None,
) -> Any:
    return DuckDBCreateTable(
        name=name,
        sql=sql,
        group=group,
        schema=schema,
        mode=mode,
        pg_attach=pg_attach,
        to_lake=to_lake,
        pre_sql=pre_sql,
        post_sql=post_sql,
        prefix=prefix,
        fmt=fmt,
    )


@server.tool()
def render_step(
    name: str,
    sql: str,
    ds: str,
    group: str = "stg",
    schema: str | None = None,
    mode: str = "replace",
    pg_attach: bool = False,
    to_lake: bool = False,
    pre_sql: str | None = None,
    post_sql: str | None = None,
    prefix: bool | None = None,
    fmt: dict[str, str] | None = None,
    prod: bool = False,
    lake: str = "~/.duck/lake",
    pg_dsn: str = "",
) -> str:
    """The exact bundle a run would ship for one partition date — every macro and
    placeholder resolved. group."name" from sql with dt prepended; mode is replace,
    insert, insert_or_ignore, insert_or_replace or upsert; <TABLE:x> and <DATEID> are the
    only macros. Returns SQL, one statement per line, the last being the receipt."""
    env = Env(prod=prod, lake=lake, pg_dsn=pg_dsn)
    step = _step(name, sql, group, schema, mode, pg_attach, to_lake, pre_sql, post_sql, prefix, fmt)
    bundle = render(step, ds, env)
    return bundle.replace(pg_dsn, "<pg_dsn>") if pg_dsn else bundle


@server.tool()
def run_step(
    name: str,
    sql: str,
    ds: str,
    group: str = "stg",
    schema: str | None = None,
    mode: str = "replace",
    pg_attach: bool = False,
    to_lake: bool = False,
    pre_sql: str | None = None,
    post_sql: str | None = None,
    prefix: bool | None = None,
    fmt: dict[str, str] | None = None,
    prod: bool = False,
    lake: str = "~/.duck/lake",
    pg_dsn: str = "",
    duck: str = "local",
    database: str = ":memory:",
    quack_uri: str = "quack:localhost:9494",
    token_file: str = "~/.duck/token",
) -> dict[str, Any]:
    """Build, ship and receipt one Step for one partition date. duck is "local" (a DuckDB at
    `database`, the default) or "quack" (the whole bundle in one quack_query on the server at
    `quack_uri`). Returns {"bundle": the SQL that shipped, DSN redacted, "receipt": the last
    statement's rows — the table's own duckdb_tables() row}."""
    env = Env(prod=prod, lake=lake, pg_dsn=pg_dsn)
    step = _step(name, sql, group, schema, mode, pg_attach, to_lake, pre_sql, post_sql, prefix, fmt)
    executor: Duck = Quack(quack_uri, token_file) if duck == "quack" else Duck(database)
    bundle, receipt = run(step, ds, executor, env)
    return {
        "bundle": bundle.replace(pg_dsn, "<pg_dsn>") if pg_dsn else bundle,
        "receipt": [list(r) for r in receipt],
    }


def main() -> None:
    server.run(transport="stdio")


if __name__ == "__main__":
    main()

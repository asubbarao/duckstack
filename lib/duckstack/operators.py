"""Dataswarm-style operators for DuckDB. Every node is an operator: an ordered bundle of SQL
plus the operators it depends on. Dependencies are operators too — a wait operator fails until
its table or partition has landed — and run() executes deps before the operator that needs them.

The operators do not know what a query is for. DuckDBCreateTable creates its table (with the ds
partition) if missing, overwrites this run's partition, optionally lands it in the lake, and
can attach Postgres read-only for the body. pre_sql/post_sql are the escape hatch. Nothing here
imports a scheduler or reads an env var: the Env is handed in at render time.
"""

import os
from typing import NamedTuple

COPY = (
    "FORMAT parquet, PARTITION_BY ({part}), OVERWRITE_OR_IGNORE, FILENAME_PATTERN 'part', "
    "COMPRESSION zstd, COMPRESSION_LEVEL 19"
)
# overwrite is INSERT OVERWRITE PARTITION: once the table exists, rerunning a day replaces that
# day and nothing else. The rest are for tables that are not day-partitioned. BY NAME
# everywhere: positional INSERT rots on the first ADD COLUMN.
MODES = {
    "overwrite": [
        "DELETE FROM {ref} WHERE {ds} = DATE '<DATEID>'",
        "INSERT INTO {ref} BY NAME {select}",
    ],
    "replace": ["CREATE OR REPLACE TABLE {ref} AS {select}"],
    "insert": ["INSERT INTO {ref} BY NAME {select}"],
    "insert_or_ignore": ["INSERT OR IGNORE INTO {ref} BY NAME {select}"],
    "insert_or_replace": ["INSERT OR REPLACE INTO {ref} BY NAME {select}"],
}


class Env(NamedTuple):
    """Where a run lands. prod decides <TABLE:x>; the rest are {placeholders}."""

    prod: bool = False
    lake: str = "~/.duck/lake"
    pg_dsn: str = ""
    writer: str = os.uname().nodename.split(".")[0].lower()


LOCAL = Env()  # the default: a laptop, non-prod, a lake under ~/.duck


class Operator(NamedTuple):
    name: str
    deps: list["Operator"]
    statements: list[str]
    fmt: dict[str, str]


def DuckDBWaitForTableOperator(table: str, group: str = "stg") -> Operator:
    """Succeeds once group.<TABLE:table> exists; until then the run fails and is retried."""
    return Operator(f"wait_{table}", [], [f"FROM {group}.<TABLE:{table}> LIMIT 0"], {})


def DuckDBWaitForPartitionsOperator(
    table: str, partitions: list[str] | None = None, group: str = "stg"
) -> Operator:
    """Succeeds once each partition — "ds=<DATEID>", or "ds=<DATEID>/country=US" — has rows."""
    checks = []
    for spec in partitions or ["ds=<DATEID>"]:
        where = " AND ".join(
            f"{k} = '{v}'" for k, v in (kv.split("=", 1) for kv in spec.split("/"))
        )
        checks.append(
            f"SELECT CASE WHEN bool_or(true) THEN '{spec}' "
            f"ELSE error('partition {spec} of {table} has not landed') END AS ready "
            f"FROM {group}.<TABLE:{table}> WHERE {where}"
        )
    return Operator(f"wait_{table}", [], checks, {})


def DuckDBCreateTable(
    name: str,
    sql: str,
    deps: list[Operator] | None = None,
    group: str = "stg",
    schema: str | None = None,
    partition: list[str] | None = None,
    mode: str = "overwrite",
    pg_attach: bool = False,
    to_lake: bool = False,
    pre_sql: str | None = None,
    post_sql: str | None = None,
    fmt: dict[str, str] | None = None,
) -> Operator:
    """group.<TABLE:name> from sql, partitioned by partition (default ["ds"]). The first
    partition column is the run's date, filled from <DATEID> — never written by the query; any
    others (country, …) come from the query's own columns.

    schema: declared columns (the date partition is added) so a key can exist; without it the
    table is created empty from the query. pg_attach: the body is Postgres SQL, run there through
    postgres_query under an alias the query never sees, READ_ONLY, detached after; <TABLE:x> in
    it is left bare, since Postgres has no test_ tables. to_lake: this run's partition out as
    hive parquet. fmt: every key is a {placeholder} in all three bodies. The bundle ends with
    the table's own catalog row, so whoever ran it gets a receipt, not a template.
    """
    part = partition or ["ds"]
    ds, pg, ref = part[0], f"pg_{name}", f"{group}.<TABLE:{name}>"
    body = f"SELECT * FROM postgres_query('{pg}', $pg${tables(sql, '')}$pg$)" if pg_attach else sql
    select = f"SELECT DATE '<DATEID>' AS {ds}, COLUMNS(c -> c <> '{ds}') FROM ({body})"
    create = (
        f"CREATE TABLE IF NOT EXISTS {ref} ({ds} DATE, {schema})"
        if schema
        else f"CREATE TABLE IF NOT EXISTS {ref} AS {select} LIMIT 0"
    )
    statements = [
        *([f"ATTACH IF NOT EXISTS '{{pg_dsn}}' AS {pg} (TYPE postgres, READ_ONLY)"] * pg_attach),
        *([pre_sql] if pre_sql else []),
        f"CREATE SCHEMA IF NOT EXISTS {group}",
        create,
        *[m.format(ref=ref, select=select, ds=ds) for m in MODES[mode]],
        *(
            [
                f"COPY (FROM {ref} WHERE {ds} = DATE '<DATEID>') TO '{{lake}}/{name}' "
                f"({COPY.format(part=', '.join(part))})"
            ]
            * to_lake
        ),
        *([post_sql] if post_sql else []),
        *([f"DETACH {pg}"] * pg_attach),
        f'SELECT schema_name AS "group", table_name AS name, '
        "estimated_size AS rows_estimated, column_count AS cols "
        f"FROM duckdb_tables() WHERE schema_name = '{group}' "
        f"AND table_name = replace('<TABLE:{name}>', '\"', '')",
    ]
    return Operator(name, deps or [], statements, fmt or {})


def render(op: Operator, ds: str, env: Env = LOCAL) -> str:
    """The bundle as one text — every macro and placeholder resolved — which is what gets
    logged and what gets shipped. Read this, not the template, when a run goes wrong."""
    return ";\n".join(resolve(s, ds, op.fmt, env) for s in op.statements)


def resolve(sql: str, ds: str, fmt: dict[str, str] | None = None, env: Env = LOCAL) -> str:
    """<TABLE:x> → "x" in production, "test_x" anywhere else. <DATEID> → the run's partition
    date, handed in by the scheduler. Nothing else is computed here: an operator that needs
    another date writes DuckDB SQL for it — DATE '<DATEID>' - 3, or a read of DuckLake's own
    metadata. {key} placeholders come from the operator's fmt row, with {lake}, {writer} and
    {pg_dsn} from the Env — the DSN is resolved here, at ship time, so an operator carries no
    secret; a replace loop, never .format(), because SQL has braces of its own."""
    pre = "" if env.prod else "test_"
    values = {
        "lake": os.path.expanduser(env.lake),
        "writer": env.writer,
        "pg_dsn": env.pg_dsn,
        **(fmt or {}),
    }
    sql = sql.replace("<DATEID>", ds)
    for k, v in values.items():
        sql = sql.replace("{" + k + "}", v)
    return tables(sql, pre)


def tables(sql: str, pre: str) -> str:
    """Every <TABLE:x> → "{pre}x". Scanned without a regex: a chunk holding whitespace is a
    comparison (a < 3), not a macro."""
    out, rest = [], sql
    while True:
        before, sep, after = rest.partition("<TABLE:")
        out.append(before)
        if not sep:
            return "".join(out)
        arg, close, rest = after.partition(">")
        if not close or any(c.isspace() for c in arg):
            raise ValueError(f"unterminated macro: <TABLE:{arg}")
        out.append(f'"{pre}{arg}"')

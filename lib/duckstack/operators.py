"""Dataswarm-style operators for DuckDB. Every node is an operator: an ordered bundle of SQL
plus the operators in its dep_list. Dependencies are operators too — a wait operator fails
until its table or partition has landed — and run() executes a dep_list before the operator.

DuckDBOperator is PrestoOperator: the author writes sql, names the table in create and the
partition in partition; the operator creates the table if missing (never the author),
overwrites that partition, optionally lands it in the lake, and can attach Postgres read-only.
The operators do not know what a query is for. Nothing here imports a scheduler or reads an
env var: the Env is handed in at render time.
"""

import os
from typing import NamedTuple

COPY = (
    "FORMAT parquet, PARTITION_BY ({part}), OVERWRITE_OR_IGNORE, FILENAME_PATTERN 'part', "
    "COMPRESSION zstd, COMPRESSION_LEVEL 19"
)
# overwrite is INSERT OVERWRITE PARTITION: once the table exists, rerunning a partition replaces
# it and nothing else. replace and insert are for tables not rebuilt by partition. BY NAME
# everywhere: positional INSERT rots on the first ADD COLUMN.
MODES = {
    "overwrite": ["DELETE FROM {ref} WHERE {where}", "INSERT INTO {ref} BY NAME {select}"],
    "replace": ["CREATE OR REPLACE TABLE {ref} AS {select}"],
    "insert": ["INSERT INTO {ref} BY NAME {select}"],
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
    namespace: str
    dep_list: list["Operator"]
    statements: list[str]
    fmt: dict[str, str]


def _in(namespace: str) -> list[str]:
    # <TABLE:x> is unqualified; the namespace is where it resolves
    return [f"CREATE SCHEMA IF NOT EXISTS {namespace}", f"SET search_path = '{namespace}'"]


def DuckDBWaitForTableOperator(table: str, namespace: str = "stg") -> Operator:
    """Succeeds once <TABLE:table> exists in namespace; until then the run fails and is
    retried."""
    return Operator(
        f"wait_{table}", namespace, [], [*_in(namespace), f"FROM <TABLE:{table}> LIMIT 0"], {}
    )


def DuckDBWaitForPartitionOperator(
    table: str, partition: str = "ds=<DATEID>", namespace: str = "stg"
) -> Operator:
    """Succeeds once the partition — "ds=<DATEID>", or "ds=<DATEID>/country=US" — has rows."""
    kv = (p.split("=", 1) for p in partition.split("/"))
    where = " AND ".join(f"{k} = '{v}'" for k, v in kv)
    check = (
        f"SELECT CASE WHEN bool_or(true) THEN 'ready' "
        f"ELSE error('partition {partition} of {table} has not landed') END AS ready "
        f"FROM <TABLE:{table}> WHERE {where}"
    )
    return Operator(f"wait_{table}", namespace, [], [*_in(namespace), check], {})


def DuckDBOperator(
    sql: str,
    create: str,
    dep_list: list[Operator] | None = None,
    namespace: str = "stg",
    partition: dict[str, str] | None = None,
    mode: str = "overwrite",
    pg_attach: bool = False,
    to_lake: bool = False,
    pre_sql: str | None = None,
    post_sql: str | None = None,
    fmt: dict[str, str] | None = None,
) -> Operator:
    """Runs sql and writes the result into partition (default {"ds": "<DATEID>"}) of the table
    named by create — <TABLE:create> in namespace. The operator writes the CREATE TABLE, never
    the author. The partition columns are the operator's, never the sql's — an
    incoming column of the same name is replaced. The table is created from the sql's
    shape the first time. No keys: DuckLake has none, so no mode depends on one.

    pg_attach: the sql is Postgres SQL, run there through postgres_query under an alias it
    never sees, READ_ONLY, detached after; its <TABLE:x> stays bare, since Postgres has no
    test_ tables. to_lake: this partition out as hive parquet. fmt: every key is a
    {placeholder} in all three bodies. The bundle ends with the table's own catalog row.
    """
    part = partition or {"ds": "<DATEID>"}
    table, pg, ref = create, f"pg_{create}", f"<TABLE:{create}>"
    body = f"SELECT * FROM postgres_query('{pg}', $pg${tables(sql, '')}$pg$)" if pg_attach else sql
    cols = ", ".join(f"'{v}'::VARCHAR AS {k}" for k, v in part.items())
    names = ", ".join(f"'{k}'" for k in part)
    shaped = f"SELECT {cols}, COLUMNS(c -> c NOT IN ({names})) FROM ({body})"
    where = " AND ".join(f"{k} = '{v}'" for k, v in part.items())
    statements = [
        *([f"ATTACH IF NOT EXISTS '{{pg_dsn}}' AS {pg} (TYPE postgres, READ_ONLY)"] * pg_attach),
        *([pre_sql] if pre_sql else []),
        *_in(namespace),
        f"CREATE TABLE IF NOT EXISTS {ref} AS {shaped} LIMIT 0",
        *[m.format(ref=ref, select=shaped, where=where) for m in MODES[mode]],
        *(
            [
                f"COPY (FROM {ref} WHERE {where}) TO '{{lake}}/{table}' "
                f"({COPY.format(part=', '.join(part))})"
            ]
            * to_lake
        ),
        *([post_sql] if post_sql else []),
        *([f"DETACH {pg}"] * pg_attach),
        f'SELECT schema_name AS namespace, table_name AS "table", '
        "estimated_size AS rows_estimated, column_count AS cols "
        f"FROM duckdb_tables() WHERE schema_name = '{namespace}' "
        f"AND table_name = replace('{ref}', '\"', '')",
    ]
    return Operator(table, namespace, dep_list or [], statements, fmt or {})


def render(op: Operator, ds: str, env: Env = LOCAL) -> str:
    """The bundle as one text — every macro and placeholder resolved except <LATEST_DS:x>,
    which only the database can answer and run() fills in. What gets logged and shipped."""
    return ";\n".join(resolve(s, ds, op.fmt, env) for s in op.statements)


def resolve(sql: str, ds: str, fmt: dict[str, str] | None = None, env: Env = LOCAL) -> str:
    """<TABLE:x> → "x" in production, "test_x" anywhere else. <DATEID> → the run's partition,
    handed in by the scheduler, inside the author's own quotes: ds = '<DATEID>'. Any other date
    is DuckDB SQL (DATE '<DATEID>' - 3) or <LATEST_DS:x>. {key} placeholders come from the
    operator's fmt row, with {lake}, {writer} and {pg_dsn} from the Env — the DSN is resolved
    here, at ship time, so an operator carries no secret; a replace loop, never .format(),
    because SQL has braces of its own."""
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


def latest_ds(sql: str) -> list[str]:
    """The x of every <LATEST_DS:x> in sql, in order."""
    return [arg for arg, _ in _macros(sql, "<LATEST_DS:")]


def tables(sql: str, pre: str) -> str:
    """Every <TABLE:x> → "{pre}x"."""
    out, rest = [], sql
    for arg, before in _macros(sql, "<TABLE:"):
        out += [before, f'"{pre}{arg}"']
        rest = rest[len(before) + len("<TABLE:") + len(arg) + 1 :]
    return "".join(out) + rest


def _macros(sql: str, macro: str) -> list[tuple[str, str]]:
    """(argument, text before it) for each macro in sql, in order. Scanned without a regex:
    a chunk holding whitespace is a comparison (a < 3), not a macro."""
    found: list[tuple[str, str]] = []
    rest = sql
    while True:
        before, sep, after = rest.partition(macro)
        if not sep:
            return found
        arg, close, rest = after.partition(">")
        if not close or any(c.isspace() for c in arg):
            raise ValueError(f"unterminated macro: {macro}{arg}")
        found.append((arg, before))

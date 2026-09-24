"""The asset factory. A step is a SELECT; the factory makes it that run's table.

The factory does not know what a step is for. It knows how to attach Postgres read-only,
create the table if it is missing, write into it the way the step chose, land it in the lake,
and take it all down. A step says whether it wants those, never how they are spelled.
pre_sql/post_sql are the escape hatch. A factory returns a Step — an ordered bundle of
statements — never a scheduler's object. A Step ships to any Duck in one call and the
bundle's last statement is its receipt. Nothing here imports a scheduler or reads an env var:
the Env is handed in at render time, so a Step carries no secret and no site value.
"""

import os
from typing import NamedTuple

COPY = (
    "FORMAT parquet, PARTITION_BY (dt), OVERWRITE_OR_IGNORE, FILENAME_PATTERN 'part', "
    "COMPRESSION zstd, COMPRESSION_LEVEL 19"
)
# The table exists by the time any of these run, so every mode is a plain write. BY NAME
# everywhere: positional INSERT rots on the first ADD COLUMN. upsert rewrites this run's
# partition — concurrent runs touch disjoint rows, so no key and no lock choreography.
MODES = {
    "replace": ["CREATE OR REPLACE TABLE {ref} AS {select}"],
    "insert": ["INSERT INTO {ref} BY NAME {select}"],
    "insert_or_ignore": ["INSERT OR IGNORE INTO {ref} BY NAME {select}"],
    "insert_or_replace": ["INSERT OR REPLACE INTO {ref} BY NAME {select}"],
    "upsert": [
        "DELETE FROM {ref} WHERE dt = DATE '<DATEID>'",
        "INSERT INTO {ref} BY NAME {select}",
    ],
}


class Env(NamedTuple):
    """Where a run lands. prod decides <TABLE:x>; the rest are {placeholders}."""

    prod: bool = False
    lake: str = "~/.duck/lake"
    pg_dsn: str = ""
    writer: str = os.uname().nodename.split(".")[0].lower()


LOCAL = Env()  # the default: a laptop, non-prod, a lake under ~/.duck


class Step(NamedTuple):
    name: str
    group: str
    deps: list["Step"]
    statements: list[str]
    dims: list[str]
    prefix: bool
    fmt: dict[str, str]


def DuckDBCreateTable(
    name: str,
    sql: str,
    deps: list[Step] | None = None,
    group: str = "stg",
    schema: str | None = None,
    mode: str = "replace",
    pg_attach: bool = False,
    to_lake: bool = False,
    pre_sql: str | None = None,
    post_sql: str | None = None,
    partition: list[str] | None = None,
    prefix: bool | None = None,
    fmt: dict[str, str] | None = None,
) -> Step:
    """group."name" from sql, with dt prepended from the run's partition — never by the step.

    schema: declared columns (dt is added) so insert_or_ignore/replace have a key to honour;
    without it the table is created empty from the SELECT and every mode still runs.
    pg_attach: the body is Postgres SQL, run there through postgres_query under an alias the
    step never sees, READ_ONLY, detached after; the test_ prefix defaults off, since the source
    has no test_ tables to be kept away from. to_lake: hive parquet out, one directory per dt.
    fmt: a config row; every key is a {placeholder} in all three bodies. The bundle ends with
    the table's own catalog row, so whoever ran it gets a receipt, not a template.
    """
    pg, ref, lake = f"pg_{name}", f'{group}."{name}"', f"{{lake}}/{name}"
    body = f"SELECT * FROM postgres_query('{pg}', $pg${sql}$pg$)" if pg_attach else sql
    select = f"SELECT DATE '<DATEID>' AS dt, * FROM ({body})"
    create = (
        f"CREATE TABLE IF NOT EXISTS {ref} (dt DATE, {schema})"
        if schema
        else f"CREATE TABLE IF NOT EXISTS {ref} AS {select} LIMIT 0"
    )
    statements = [
        *([f"ATTACH IF NOT EXISTS '{{pg_dsn}}' AS {pg} (TYPE postgres, READ_ONLY)"] * pg_attach),
        *([pre_sql] if pre_sql else []),
        f"CREATE SCHEMA IF NOT EXISTS {group}",
        create,
        *[m.format(ref=ref, select=select) for m in MODES[mode]],
        *([f"COPY (SELECT * FROM {ref}) TO '{lake}' ({COPY})"] * to_lake),
        *([post_sql] if post_sql else []),
        *([f"DETACH {pg}"] * pg_attach),
        f"SELECT '{group}' AS \"group\", '{name}' AS name, "
        "estimated_size AS rows_estimated, column_count AS cols "
        f"FROM duckdb_tables() WHERE schema_name = '{group}' AND table_name = '{name}'",
    ]
    return Step(
        name,
        group,
        deps or [],
        statements,
        partition or ["DATEID"],
        not pg_attach if prefix is None else prefix,
        fmt or {},
    )


def render(step: Step, ds: str, env: Env = LOCAL) -> str:
    """The bundle as one text — every macro and placeholder resolved — which is what gets
    logged and what gets shipped. Read this, not the template, when a run goes wrong."""
    return ";\n".join(resolve(s, ds, step.prefix, step.fmt, env) for s in step.statements)


def resolve(
    sql: str, ds: str, prefix: bool = True, fmt: dict[str, str] | None = None, env: Env = LOCAL
) -> str:
    """<TABLE:x> → "x" in production, "test_x" anywhere else. <DATEID> → the run's partition
    date, handed in by the scheduler. Nothing else is computed here: a step that needs another
    date writes DuckDB SQL for it — DATE '<DATEID>' - 3, or a read of DuckLake's own metadata.
    {key} placeholders come from the step's fmt row, with {lake}, {writer} and {pg_dsn} from
    the Env — the DSN is resolved here, at ship time, so a Step carries no secret; a replace
    loop, never .format(), because SQL has braces of its own. Scanned without a regex: a chunk
    holding whitespace is a comparison (a < 3), not a macro."""
    pre = "" if not prefix or env.prod else "test_"
    values = {
        "lake": os.path.expanduser(env.lake),
        "writer": env.writer,
        "pg_dsn": env.pg_dsn,
        **(fmt or {}),
    }
    sql = sql.replace("<DATEID>", ds)
    for k, v in values.items():
        sql = sql.replace("{" + k + "}", v)
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

"""Every statement the factory emits, executed on a real local DuckDB. Nothing is stubbed
except pg_attach, which needs a Postgres to run and is checked as rendered text."""

from pathlib import Path
from typing import Any

import duckdb
import pytest

from duckstack import Duck, DuckDBCreateTable, Env, Step, resolve, run

DS = "2026-09-22"


@pytest.fixture
def env(tmp_path: Path) -> Env:
    return Env(prod=False, lake=str(tmp_path / "lake"), pg_dsn="postgres://u:secret@h/db")


@pytest.fixture
def duck() -> Duck:
    d = Duck()
    d.execute(
        "CREATE SCHEMA src;CREATE TABLE src.orders AS FROM (VALUES (1, 10), (2, 20)) t(id, amt)"
    )
    return d


def rows(duck: Duck, table: str) -> list[tuple[object, ...]]:
    return duck.execute(f"SELECT dt::VARCHAR, id, amt FROM stg.{table} ORDER BY dt, id")


def orders(name: str, **kw: Any) -> Step:
    return DuckDBCreateTable(name=name, sql="FROM src.orders", **kw)


# --- resolve: the only macros are <TABLE:x>, <DATEID> and {placeholders} ---


def test_table_macro_is_test_prefixed_off_prod_and_bare_in_prod(env: Env) -> None:
    assert resolve("FROM <TABLE:orders>", DS, env=env) == 'FROM "test_orders"'
    assert resolve("FROM <TABLE:orders>", DS, env=Env(prod=True)) == 'FROM "orders"'
    assert resolve("FROM <TABLE:orders>", DS, prefix=False, env=env) == 'FROM "orders"'


def test_dateid_and_placeholders_resolve_and_comparisons_survive(env: Env) -> None:
    sql = "WHERE a < 3 AND b > 1 AND dt = DATE '<DATEID>' - 3 AND w = '{writer}' AND f = {floor}"
    out = resolve(sql, DS, fmt={"floor": "20"}, env=env)
    assert out == (
        f"WHERE a < 3 AND b > 1 AND dt = DATE '{DS}' - 3 AND w = '{env.writer}' AND f = 20"
    )


def test_unterminated_table_macro_raises(env: Env) -> None:
    for bad in ["FROM <TABLE:orders", "FROM <TABLE:orders WHERE a > 1"]:
        with pytest.raises(ValueError, match="unterminated"):
            resolve(bad, DS, env=env)


# --- modes: CREATE TABLE IF NOT EXISTS first, then the chosen write ---


def test_replace_keeps_only_the_latest_run(duck: Duck, env: Env) -> None:
    step = orders("t_replace")
    run(step, DS, duck, env)
    duck.execute("DELETE FROM src.orders WHERE id = 1")
    run(step, DS, duck, env)
    assert rows(duck, "t_replace") == [(DS, 2, 20)]


def test_insert_appends_every_run(duck: Duck, env: Env) -> None:
    step = orders("t_insert", mode="insert")
    run(step, DS, duck, env)
    run(step, DS, duck, env)
    assert rows(duck, "t_insert") == [(DS, 1, 10), (DS, 1, 10), (DS, 2, 20), (DS, 2, 20)]


KEYED = "id INTEGER, amt INTEGER, PRIMARY KEY (dt, id)"


def test_insert_or_ignore_keeps_the_first_value_for_a_key(duck: Duck, env: Env) -> None:
    step = orders("t_ignore", mode="insert_or_ignore", schema=KEYED)
    run(step, DS, duck, env)
    duck.execute("UPDATE src.orders SET amt = 99 WHERE id = 2")
    run(step, DS, duck, env)
    assert rows(duck, "t_ignore") == [(DS, 1, 10), (DS, 2, 20)]


def test_insert_or_replace_takes_the_new_value_for_a_key(duck: Duck, env: Env) -> None:
    # columns in the opposite order to the table: a positional INSERT would swap them
    step = DuckDBCreateTable(
        name="t_repl", sql="SELECT amt, id FROM src.orders", mode="insert_or_replace", schema=KEYED
    )
    run(step, DS, duck, env)
    duck.execute("UPDATE src.orders SET amt = 99 WHERE id = 2")
    run(step, DS, duck, env)
    assert rows(duck, "t_repl") == [(DS, 1, 10), (DS, 2, 99)]


def test_upsert_rewrites_its_partition_and_keeps_others(duck: Duck, env: Env) -> None:
    step = orders("t_upsert", mode="upsert")
    run(step, "2026-09-21", duck, env)
    run(step, DS, duck, env)
    duck.execute("UPDATE src.orders SET amt = 99 WHERE id = 2")
    run(step, DS, duck, env)
    assert rows(duck, "t_upsert") == [
        ("2026-09-21", 1, 10),
        ("2026-09-21", 2, 20),
        (DS, 1, 10),
        (DS, 2, 99),
    ]


def test_unknown_mode_is_refused() -> None:
    with pytest.raises(KeyError, match="merge"):
        orders("t_bad", mode="merge")


# --- the rest of the bundle: pre/post sql, lake copy, receipt ---


def test_pre_sql_runs_before_and_post_sql_after_the_write(duck: Duck, env: Env) -> None:
    step = DuckDBCreateTable(
        name="t_hooks",
        sql="FROM src.staged",
        pre_sql="CREATE TABLE src.staged AS FROM src.orders WHERE id = 1",
        post_sql="CREATE TABLE src.after AS SELECT sum(amt) AS total FROM stg.t_hooks",
    )
    run(step, DS, duck, env)
    assert rows(duck, "t_hooks") == [(DS, 1, 10)]
    assert duck.execute("FROM src.after") == [(10,)]


def test_to_lake_lands_one_hive_partition_readable_back(duck: Duck, env: Env) -> None:
    run(orders("t_lake", to_lake=True), DS, duck, env)
    run(orders("t_lake", to_lake=True), DS, duck, env)  # a rerun overwrites, never duplicates
    files = sorted(p.relative_to(env.lake).as_posix() for p in Path(env.lake).rglob("*.parquet"))
    assert files == [f"t_lake/dt={DS}/part0.parquet"]
    back = duckdb.sql(
        f"SELECT dt::VARCHAR, id, amt FROM read_parquet('{env.lake}/t_lake/**/*.parquet', "
        "hive_partitioning = true) ORDER BY id"
    ).fetchall()
    assert back == [(DS, 1, 10), (DS, 2, 20)]


def test_receipt_is_the_tables_own_catalog_row(duck: Duck, env: Env) -> None:
    run(orders("t_other", group="mart"), DS, duck, env)
    _, receipt = run(orders("t_receipt", group="mart"), DS, duck, env)
    assert receipt == [("mart", "t_receipt", 2, 3)]  # group, name, rows_estimated, cols


# --- pg_attach: rendered only; the DSN is resolved at ship time and redacted in the log ---


class Capture(Duck):
    def __init__(self) -> None:
        self.seen: list[str] = []

    def execute(self, bundle: str) -> list[object]:
        self.seen.append(bundle)
        return []


def test_pg_attach_wraps_the_body_read_only_and_keeps_the_dsn_out_of_logs(env: Env) -> None:
    step = DuckDBCreateTable(name="sub", pg_attach=True, sql="SELECT * FROM <TABLE:submission>")
    cap, logged = Capture(), list[str]()
    bundle, _ = run(step, DS, cap, env, log=logged.append)
    stmts = bundle.split(";\n")
    assert stmts[0] == f"ATTACH IF NOT EXISTS '{env.pg_dsn}' AS pg_sub (TYPE postgres, READ_ONLY)"
    assert "postgres_query('pg_sub', $pg$SELECT * FROM \"submission\"$pg$)" in bundle
    assert stmts[-2] == "DETACH pg_sub"
    assert cap.seen == [bundle]
    assert env.pg_dsn not in logged[0] and "<pg_dsn>" in logged[0]
    assert not any(env.pg_dsn in s for s in step.statements)

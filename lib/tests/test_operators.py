"""Every operator, executed on a real local DuckDB. Nothing is stubbed except pg_attach, which
needs a Postgres to run and is checked as rendered text."""

from pathlib import Path

import duckdb
import pytest

from duckstack import (
    Duck,
    DuckDBOperator,
    DuckDBWaitForPartitionOperator,
    DuckDBWaitForTableOperator,
    Env,
    resolve,
    run,
)

DS = "2026-09-22"
ORDERS = "SELECT * FROM src.orders"


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
    return duck.execute(f'SELECT ds, id, amt FROM stg."test_{table}" ORDER BY ds, id')


# --- resolve: <TABLE:x>, <DATEID> and {placeholders} ---


def test_table_macro_is_test_prefixed_off_prod_and_bare_in_prod(env: Env) -> None:
    assert resolve("FROM <TABLE:orders>", DS, env=env) == 'FROM "test_orders"'
    assert resolve("FROM <TABLE:orders>", DS, env=Env(prod=True)) == 'FROM "orders"'


def test_dateid_and_placeholders_resolve_and_comparisons_survive(env: Env) -> None:
    sql = "WHERE a < 3 AND b > 1 AND ds = '<DATEID>' AND w = '{writer}' AND f = {floor}"
    out = resolve(sql, DS, fmt={"floor": "20"}, env=env)
    assert out == f"WHERE a < 3 AND b > 1 AND ds = '{DS}' AND w = '{env.writer}' AND f = 20"


def test_unterminated_table_macro_raises(env: Env) -> None:
    for bad in ["FROM <TABLE:orders", "FROM <TABLE:orders WHERE a > 1"]:
        with pytest.raises(ValueError, match="unterminated"):
            resolve(bad, DS, env=env)


# --- DuckDBOperator: the operator creates the table, then INSERT OVERWRITE PARTITION ---


def test_overwrite_rewrites_its_partition_and_keeps_others(duck: Duck, env: Env) -> None:
    op = DuckDBOperator(sql=ORDERS, create="t_over", partition={"ds": "<DATEID>"})
    run(op, "2026-09-21", duck, env)
    run(op, DS, duck, env)
    duck.execute("UPDATE src.orders SET amt = 99 WHERE id = 2")
    run(op, DS, duck, env)
    assert rows(duck, "t_over") == [
        ("2026-09-21", 1, 10),
        ("2026-09-21", 2, 20),
        (DS, 1, 10),
        (DS, 2, 99),
    ]


def test_output_table_is_prod_named_in_prod(duck: Duck, env: Env) -> None:
    run(DuckDBOperator(sql=ORDERS, create="t_prod"), DS, duck, env._replace(prod=True))
    assert duck.execute('SELECT id FROM stg."t_prod" ORDER BY id') == [(1,), (2,)]


def test_every_partition_key_is_the_operators_and_lands_in_the_lake(duck: Duck, env: Env) -> None:
    op = DuckDBOperator(
        sql="SELECT *, 'XX' AS country FROM src.orders",  # replaced, not duplicated
        create="t_cc",
        partition={"ds": "<DATEID>", "country": "US"},
        to_lake=True,
    )
    run(op, DS, duck, env)
    assert duck.execute('SELECT DISTINCT ds, country FROM stg."test_t_cc"') == [(DS, "US")]
    files = sorted(p.relative_to(env.lake).as_posix() for p in Path(env.lake).rglob("*.parquet"))
    assert files == [f"t_cc/ds={DS}/country=US/part0.parquet"]


def test_replace_keeps_only_the_latest_run(duck: Duck, env: Env) -> None:
    op = DuckDBOperator(sql=ORDERS, create="t_replace", mode="replace")
    run(op, DS, duck, env)
    duck.execute("DELETE FROM src.orders WHERE id = 1")
    run(op, DS, duck, env)
    assert rows(duck, "t_replace") == [(DS, 2, 20)]


def test_insert_appends_every_run(duck: Duck, env: Env) -> None:
    op = DuckDBOperator(sql=ORDERS, create="t_insert", mode="insert")
    run(op, DS, duck, env)
    run(op, DS, duck, env)
    assert rows(duck, "t_insert") == [(DS, 1, 10), (DS, 1, 10), (DS, 2, 20), (DS, 2, 20)]


def test_insert_or_ignore_keeps_the_first_value_for_a_key(duck: Duck, env: Env) -> None:
    op = DuckDBOperator(sql=ORDERS, create="t_ignore", mode="insert_or_ignore", key="ds, id")
    run(op, DS, duck, env)
    duck.execute("UPDATE src.orders SET amt = 99 WHERE id = 2")
    run(op, DS, duck, env)
    assert rows(duck, "t_ignore") == [(DS, 1, 10), (DS, 2, 20)]


def test_insert_or_replace_takes_the_new_value_for_a_key(duck: Duck, env: Env) -> None:
    op = DuckDBOperator(sql=ORDERS, create="t_repl", mode="insert_or_replace", key="ds, id")
    run(op, DS, duck, env)
    duck.execute("UPDATE src.orders SET amt = 99 WHERE id = 2")
    # columns in the opposite order to the table: a positional INSERT would swap them
    swapped = DuckDBOperator(
        sql="SELECT amt, id FROM src.orders",
        create="t_repl",
        mode="insert_or_replace",
        key="ds, id",
    )
    run(swapped, DS, duck, env)
    assert rows(duck, "t_repl") == [(DS, 1, 10), (DS, 2, 99)]


def test_unknown_mode_is_refused() -> None:
    with pytest.raises(KeyError, match="merge"):
        DuckDBOperator(sql=ORDERS, create="t_bad", mode="merge")


def test_pre_sql_runs_before_and_post_sql_after_the_write(duck: Duck, env: Env) -> None:
    op = DuckDBOperator(
        sql="FROM src.staged",
        create="t_hooks",
        pre_sql="CREATE TABLE src.staged AS FROM src.orders WHERE id = 1",
        post_sql="CREATE TABLE src.after AS SELECT sum(amt) AS total FROM <TABLE:t_hooks>",
    )
    run(op, DS, duck, env)
    assert rows(duck, "t_hooks") == [(DS, 1, 10)]
    assert duck.execute("FROM src.after") == [(10,)]


def test_to_lake_lands_this_partition_and_a_rerun_overwrites(duck: Duck, env: Env) -> None:
    op = DuckDBOperator(sql=ORDERS, create="t_lake", to_lake=True)
    run(op, "2026-09-21", duck, env)
    run(op, DS, duck, env)
    run(op, DS, duck, env)
    files = sorted(p.relative_to(env.lake).as_posix() for p in Path(env.lake).rglob("*.parquet"))
    assert files == ["t_lake/ds=2026-09-21/part0.parquet", f"t_lake/ds={DS}/part0.parquet"]
    back = duckdb.sql(
        f"SELECT id, amt FROM read_parquet('{env.lake}/t_lake/ds={DS}/*.parquet') ORDER BY id"
    ).fetchall()
    assert back == [(1, 10), (2, 20)]


def test_receipt_is_the_tables_own_catalog_row(duck: Duck, env: Env) -> None:
    run(DuckDBOperator(sql=ORDERS, create="t_other", namespace="mart"), DS, duck, env)
    op = DuckDBOperator(sql=ORDERS, create="t_receipt", namespace="mart")
    [(_, _, receipt)] = run(op, DS, duck, env)
    assert receipt == [("mart", "test_t_receipt", 2, 3)]  # namespace, table, rows_est, cols


# --- dep_list: waits are dependencies; run() executes the dep_list first, each once ---


def test_wait_for_table_fails_until_the_table_exists(duck: Duck, env: Env) -> None:
    op = DuckDBOperator(
        dep_list=[DuckDBWaitForTableOperator("t_up")],
        sql="FROM <TABLE:t_up> WHERE ds = '<DATEID>'",
        create="t_down",
    )
    with pytest.raises(duckdb.CatalogException):
        run(op, DS, duck, env)
    run(DuckDBOperator(sql=ORDERS, create="t_up"), DS, duck, env)
    run(op, DS, duck, env)
    assert rows(duck, "t_down") == [(DS, 1, 10), (DS, 2, 20)]


def test_wait_for_partition_fails_until_that_day_has_landed(duck: Duck, env: Env) -> None:
    up = DuckDBOperator(sql=ORDERS, create="t_up")
    run(up, "2026-09-21", duck, env)
    op = DuckDBOperator(
        dep_list=[DuckDBWaitForPartitionOperator(table="t_up", partition="ds=<DATEID>")],
        sql="FROM <TABLE:t_up> WHERE ds = '<DATEID>'",
        create="t_down",
    )
    with pytest.raises(duckdb.InvalidInputException, match="has not landed"):
        run(op, DS, duck, env)
    run(up, DS, duck, env)
    run(op, DS, duck, env)
    assert rows(duck, "t_down") == [(DS, 1, 10), (DS, 2, 20)]


def test_dep_list_runs_first_and_a_shared_dep_runs_once(duck: Duck, env: Env) -> None:
    up = DuckDBOperator(sql=ORDERS, create="t_up")
    daily = "FROM <TABLE:t_up> WHERE ds = '<DATEID>'"
    left = DuckDBOperator(dep_list=[up], sql=daily, create="t_left")
    right = DuckDBOperator(dep_list=[up], sql=daily, create="t_right")
    top = DuckDBOperator(
        dep_list=[left, right],
        sql="SELECT id, amt FROM <TABLE:t_left> WHERE ds = '<DATEID>' "
        "UNION ALL SELECT id, amt FROM <TABLE:t_right> WHERE ds = '<DATEID>'",
        create="t_top",
    )
    ran = run(top, DS, duck, env)
    assert [name for name, _, _ in ran] == ["t_up", "t_left", "t_right", "t_top"]
    assert rows(duck, "t_top") == [(DS, 1, 10), (DS, 1, 10), (DS, 2, 20), (DS, 2, 20)]


def test_latest_ds_is_the_newest_partition_the_database_holds(duck: Duck, env: Env) -> None:
    up = DuckDBOperator(sql=ORDERS, create="t_up")
    run(up, "2026-09-20", duck, env)
    duck.execute("UPDATE src.orders SET amt = 99 WHERE id = 2")
    run(up, "2026-09-21", duck, env)
    snap = DuckDBOperator(
        sql="SELECT id, amt FROM <TABLE:t_up> WHERE ds = '<LATEST_DS:t_up>'", create="t_snap"
    )
    [(_, bundle, _)] = run(snap, DS, duck, env)
    assert "ds = '2026-09-21'" in bundle
    assert rows(duck, "t_snap") == [(DS, 1, 10), (DS, 2, 99)]


def test_latest_ds_of_an_empty_table_refuses_to_guess(duck: Duck, env: Env) -> None:
    duck.execute('CREATE SCHEMA stg; CREATE TABLE stg."test_t_empty" (ds VARCHAR, id INT)')
    snap = DuckDBOperator(
        sql="FROM <TABLE:t_empty> WHERE ds = '<LATEST_DS:t_empty>'", create="t_snap"
    )
    with pytest.raises(LookupError, match="no partitions"):
        run(snap, DS, duck, env)


# --- pg_attach: rendered only; the DSN is resolved at ship time and redacted in the log ---


class Capture(Duck):
    def __init__(self) -> None:
        self.seen: list[str] = []

    def execute(self, bundle: str) -> list[object]:
        self.seen.append(bundle)
        return []


def test_pg_attach_wraps_the_sql_read_only_and_keeps_the_dsn_out_of_logs(env: Env) -> None:
    op = DuckDBOperator(sql="SELECT * FROM <TABLE:submission>", create="sub", pg_attach=True)
    cap, logged = Capture(), list[str]()
    [(_, bundle, _)] = run(op, DS, cap, env, log=logged.append)
    stmts = bundle.split(";\n")
    assert stmts[0] == f"ATTACH IF NOT EXISTS '{env.pg_dsn}' AS pg_sub (TYPE postgres, READ_ONLY)"
    assert "postgres_query('pg_sub', $pg$SELECT * FROM \"submission\"$pg$)" in bundle
    assert 'CREATE TABLE IF NOT EXISTS "test_sub"' in bundle  # the output still follows env
    assert stmts[-2] == "DETACH pg_sub"
    assert cap.seen == [bundle]
    assert env.pg_dsn not in logged[0] and "<pg_dsn>" in logged[0]
    assert not any(env.pg_dsn in s for s in op.statements)

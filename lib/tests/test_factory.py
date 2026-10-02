import os
import subprocess
import sys
from dataclasses import replace
from uuid import uuid4

import duckdb
import pytest

from duckstack import (
    ConnectToDatabase,
    DuckDBCreateTableWithSchemaOperator,
    PostgresCreateTableWithSchemaOperator,
    col,
    compile_operator,
    execute_operator,
)


@pytest.fixture
def database():
    connection = ConnectToDatabase()
    yield connection
    connection.close()


def daily(database):
    return DuckDBCreateTableWithSchemaOperator(
        create="daily",
        schema={"ds": "VARCHAR", "id": "INTEGER", "amount": "INTEGER"},
        sql="SELECT 1 AS id, 10 AS amount",
        database=database,
        partition={"ds": "<DATEID>"},
    )


def test_changed_and_empty_reruns_keep_other_partition(database):
    op = daily(database)
    execute_operator(op, "2026-10-01")
    execute_operator(op, "2026-10-02")
    execute_operator(replace(op, sql="SELECT 1 AS id, 99 AS amount"), "2026-10-02")
    assert database.execute("SELECT * FROM daily ORDER BY ds") == [
        ("2026-10-01", 1, 10),
        ("2026-10-02", 1, 99),
    ]
    execute_operator(replace(op, sql="SELECT 1 AS id, 99 AS amount WHERE false"), "2026-10-02")
    assert database.execute("SELECT * FROM daily") == [("2026-10-01", 1, 10)]


def test_checks_prevent_publication_and_empty_can_pass(database):
    op = (
        daily(database)
        .DQCheck(type=col.NOTNULL, column="id")
        .DQCheck(
            name="unique_id",
            sql="SELECT id FROM <TABLE> GROUP BY id HAVING sum(1) > 1",
        )
    )
    execute_operator(op, "today")
    for sql, message in [
        ("SELECT NULL::INTEGER AS id, 20 AS amount", "id_not_null"),
        ("SELECT 1 AS id, 20 AS amount UNION ALL SELECT 1, 30", "unique_id"),
    ]:
        with pytest.raises(duckdb.Error, match=message):
            execute_operator(replace(op, sql=sql), "today")
        assert database.execute("SELECT * FROM daily") == [("today", 1, 10)]
    execute_operator(replace(op, sql="SELECT 1 AS id, 10 AS amount WHERE false"), "today")
    assert database.execute("SELECT * FROM daily") == []


def test_typed_stage_rejects_bad_data_before_replacement(database):
    op = daily(database)
    execute_operator(op, "today")
    with pytest.raises(duckdb.Error):
        execute_operator(replace(op, sql="SELECT 1 AS id, 'bad' AS amount"), "today")
    assert database.execute("SELECT * FROM daily") == [("today", 1, 10)]


def test_quoting_and_column_order(database):
    op = DuckDBCreateTableWithSchemaOperator(
        create='orders"quoted',
        namespace="schema'quoted",
        schema={"ds": "VARCHAR", 'id"q': "INTEGER", "amount": "INTEGER"},
        partition={"ds": "O'Reilly"},
        sql='SELECT 20 AS amount, 7 AS "id""q"',
        database=database,
    ).DQCheck(type=col.NOTNULL, column='id"q')
    execute_operator(op)
    assert database.execute('SELECT * FROM "schema\'quoted"."orders""quoted"') == [
        ("O'Reilly", 7, 20),
    ]


def test_core_does_not_import_optional_dependencies():
    result = subprocess.run(
        [
            sys.executable,
            "-c",
            "import duckstack,sys; assert 'dagster' not in sys.modules; "
            "assert 'psycopg' not in sys.modules",
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr


def test_connection_and_schema_validation(database):
    with pytest.raises(ValueError, match="requires a connection"):
        execute_operator(
            PostgresCreateTableWithSchemaOperator(
                create="t",
                schema={"id": "INTEGER"},
                sql="SELECT 1 AS id",
            )
        )
    with pytest.raises(ValueError, match="cannot use"):
        execute_operator(replace(daily(database), dialect="postgres"), "today")
    with pytest.raises(ValueError, match="requires a partition"):
        compile_operator(replace(daily(database), sql="SELECT '<DATEID>' AS id"))


@pytest.mark.skipif(
    not os.environ.get("DUCKSTACK_TEST_POSTGRES_DSN"), reason="dedicated test DB required"
)
def test_real_postgres_checked_replacement():
    # The fixture DSN must identify a disposable test database, never application data.
    database = ConnectToDatabase(db=os.environ["DUCKSTACK_TEST_POSTGRES_DSN"], type="postgres")
    op = (
        PostgresCreateTableWithSchemaOperator(
            create="checked",
            namespace="duckstack_factory_test",
            schema={"ds": "TEXT", "id": "INTEGER", "amount": "INTEGER"},
            database=database,
            partition={"ds": "<DATEID>"},
            sql="SELECT 1 AS id, 10 AS amount",
        )
        .DQCheck(type=col.NOTNULL, column="id")
        .DQCheck(
            name="unique_id",
            sql="SELECT id FROM <TABLE> GROUP BY id HAVING sum(1) > 1",
        )
    )
    execute_operator(op, "first")
    execute_operator(op, "second")
    execute_operator(replace(op, sql="SELECT 1 AS id, 20 AS amount"), "second")
    assert database.execute("SELECT * FROM duckstack_factory_test.checked ORDER BY ds") == [
        ("first", 1, 10),
        ("second", 1, 20),
    ]
    for sql, name in [
        ("SELECT NULL::INTEGER AS id, 10 AS amount", "id_not_null"),
        ("SELECT 1 AS id, 10 AS amount UNION ALL SELECT 1, 20", "unique_id"),
    ]:
        with pytest.raises(Exception, match=name):
            execute_operator(replace(op, sql=sql), "second")
        assert database.execute(
            "SELECT amount FROM duckstack_factory_test.checked WHERE ds='second'"
        ) == [(20,)]
    execute_operator(replace(op, sql="SELECT 1 AS id, 20 AS amount WHERE false"), "second")
    assert database.execute("SELECT * FROM duckstack_factory_test.checked") == [("first", 1, 10)]


@pytest.mark.parametrize(
    "transport,variable",
    [
        ("quack", "DUCKSTACK_TEST_QUACK_URI"),
        ("quackapi", "DUCKSTACK_TEST_QUACKAPI_URL"),
    ],
)
def test_selected_remote_checked_reruns(transport, variable):
    endpoint = os.environ.get(variable)
    if not endpoint:
        pytest.skip("explicit selected remote test endpoint required")
    database = ConnectToDatabase(db=endpoint, type=transport)
    namespace = "duckstack_factory_test_" + uuid4().hex
    op = replace(daily(database), namespace=namespace).DQCheck(type=col.NOTNULL, column="id")
    try:
        execute_operator(op, "first")
        execute_operator(replace(op, sql="SELECT 1 AS id, 20 AS amount"), "first")
        with pytest.raises(Exception, match="id_not_null"):
            execute_operator(replace(op, sql="SELECT NULL::INTEGER AS id, 99 AS amount"), "first")
        assert database.execute(f'SELECT * FROM "{namespace}".daily') == [("first", 1, 20)]
        execute_operator(replace(op, sql="SELECT 1 AS id, 10 AS amount WHERE false"), "first")
        assert database.execute(f'SELECT * FROM "{namespace}".daily') == []
    finally:
        database.execute(f'DROP SCHEMA IF EXISTS "{namespace}" CASCADE')

from dataclasses import replace

import dagster as dg
from toposort import CircularDependencyError

from duckstack import ConnectToDatabase, DuckDBCreateTableWithSchemaOperator, col
from duckstack.dagster_adapter import assets, definitions


def example(database=None):
    return DuckDBCreateTableWithSchemaOperator(
        create="upstream",
        schema={"id": "INTEGER"},
        sql="SELECT 1 AS id",
        database=database,
    ).DQCheck(type=col.NOTNULL, column="id")


def test_generated_assets_checks_and_default_connection():
    up = example()
    down = DuckDBCreateTableWithSchemaOperator(
        create="downstream",
        schema={"id": "INTEGER"},
        sql="SELECT id FROM upstream",
        deps=(up,),
    )
    result = dg.materialize(assets([up, down]))
    assert result.success
    evaluations = result.get_asset_check_evaluations()
    assert [(e.check_name, e.passed) for e in evaluations] == [("id_not_null", True)]
    assert len(result.get_asset_materialization_events()) == 2


def test_failed_check_blocks_downstream_without_publication():
    database = ConnectToDatabase()
    up = replace(example(database), sql="SELECT NULL::INTEGER AS id")
    down = DuckDBCreateTableWithSchemaOperator(
        create="downstream",
        schema={"id": "INTEGER"},
        sql="SELECT id FROM upstream",
        deps=(up,),
    )
    result = dg.materialize(assets([up, down], database=database), raise_on_error=False)
    assert not result.success
    assert not result.get_asset_materialization_events()
    assert [(e.check_name, e.passed) for e in result.get_asset_check_evaluations()] == [
        ("id_not_null", False),
    ]
    assert (
        database.execute(
            "SELECT table_name FROM information_schema.tables "
            "WHERE table_name IN ('upstream','downstream')"
        )
        == []
    )
    database.close()


def test_dagster_retries_one_operator_not_dependencies():
    database = ConnectToDatabase()

    class Flaky:
        def __init__(self, fail_first=False):
            self.calls = 0
            self.fail_first = fail_first

        def execute(self, sql):
            self.calls += 1
            if self.fail_first and self.calls == 1:
                raise ConnectionError("transient before submission")
            return database.execute(sql)

    stable, flaky = Flaky(), Flaky(fail_first=True)
    upstream = example(stable)
    downstream = DuckDBCreateTableWithSchemaOperator(
        create="downstream",
        schema={"id": "INTEGER"},
        sql="SELECT id FROM upstream",
        deps=(upstream,),
        database=flaky,
    )
    result = dg.materialize(
        assets(
            [upstream, downstream],
            retry_policy=dg.RetryPolicy(max_retries=1),
        )
    )
    assert result.success
    assert stable.calls == 1
    assert flaky.calls == 2
    assert any(event.is_step_restarted for event in result.all_events)
    database.close()


def test_hourly_partition_key_is_not_truncated():
    database = ConnectToDatabase()
    op = DuckDBCreateTableWithSchemaOperator(
        create="hours",
        schema={"hour": "VARCHAR", "id": "INTEGER"},
        sql="SELECT 1 AS id",
        partition={"hour": "<DATEID>"},
    )
    result = dg.materialize(
        assets(
            [op],
            database=database,
            partitions_def=dg.HourlyPartitionsDefinition(start_date="2026-01-01-00:00"),
        ),
        partition_key="2026-01-01-05:00",
    )
    assert result.success
    assert database.execute("SELECT * FROM hours") == [("2026-01-01-05:00", 1)]
    database.close()


def test_dagster_validates_cycles():
    left = example()
    right = replace(left, create="right", deps=(left,))
    object.__setattr__(left, "deps", (right,))
    import pytest

    with pytest.raises((dg.DagsterInvalidDefinitionError, CircularDependencyError)):
        dg.Definitions.validate_loadable(definitions([left, right]))

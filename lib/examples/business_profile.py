"""Small local demonstration, not the real business-profile pipeline or data."""

from duckstack import DuckDBCreateTableWithSchemaOperator, col
from duckstack.dagster_adapter import definitions

source_records = DuckDBCreateTableWithSchemaOperator(
    create="source_records",
    schema={"id": "INTEGER", "legal_name": "VARCHAR"},
    sql="SELECT 1 AS id, 'Example Builder' AS legal_name",
).DQCheck(type=col.NOTNULL, column="id").DQCheck(
    name="unique_id",
    sql="SELECT id FROM <TABLE> GROUP BY id HAVING sum(1) > 1",
)

entities = DuckDBCreateTableWithSchemaOperator(
    create="entities",
    deps=(source_records,),
    schema={"id": "INTEGER", "label": "VARCHAR"},
    sql="SELECT id, legal_name AS label FROM main.source_records",
).DQCheck(type=col.NOTNULL, column="label")

defs = definitions([source_records, entities])

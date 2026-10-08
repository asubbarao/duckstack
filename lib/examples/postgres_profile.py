"""PostgreSQL declarations; supply a connection when loading these definitions.

No connection is opened at import. The deployment loader supplies its configured
ConnectToDatabase(db=..., type="postgres") to definitions(operators, database=...).
"""

from duckstack import PostgresCreateTableWithSchemaOperator, col

source_records = (
    PostgresCreateTableWithSchemaOperator(
        create="source_records",
        namespace="example_profile",
        schema={"id": "INTEGER", "legal_name": "TEXT"},
        sql="SELECT 1 AS id, 'Example Builder' AS legal_name",
    )
    .DQCheck(type=col.NOTNULL, column="id")
    .DQCheck(
        name="unique_id",
        sql="SELECT id FROM <TABLE> GROUP BY id HAVING sum(1) > 1",
    )
)

entities = PostgresCreateTableWithSchemaOperator(
    create="entities",
    namespace="example_profile",
    deps=(source_records,),
    schema={"id": "INTEGER", "label": "TEXT"},
    sql="SELECT id, legal_name AS label FROM example_profile.source_records",
).DQCheck(type=col.NOTNULL, column="label")

operators = [source_records, entities]

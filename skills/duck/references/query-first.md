# Start with the query
Alok's workflow: SQL is the interactive workspace. Run the SELECT, inspect its rows, change it, and rerun it. A file can contain several independent queries; select the one that answers the question. Do not build tables, views, COPY targets, macros, or a generator framework before the base query is correct. Persist an object only after actual repeated use justifies it.

## Choose a working shape
- Inspect a committed repository: use duck-tails [native LATERAL examples](../../duck-tails/references/lateral-queries.sql). Filter source rows first; carry absolute git_uri values.
- Rotate columns into inspectable cells: use UNPIVOT. Keep keys outside the rotation. Use INCLUDE NULLS when empty cells are part of the grain.
- Generate fake data: name each generator in a SELECT, then UNPIVOT if the next stage needs rows. Join recipes by explicit keys; do not invent a giant keyword CASE.
- Expand an existing list: SELECT unnest(items). Repeat a row with SELECT unnest(range(n)). No CROSS JOIN or any_value in agent-authored queries.
- A literal-only reader needs a column: check for a documented native _each function; otherwise use existing dev self-dispatch. A native correlated JOIN LATERAL is not a Cartesian product.
- Read or execute host output: a native reader or ShellFS FROM clause is already a relation; it does not need a wrapper view.

## Runnable fake-value query
Requires LOAD fakeit on the selected dev service. No database objects or output files are created.

```sql
WITH fake_people AS (
    SELECT range AS row_id,
        fakeit_name_first() AS first_name,
        fakeit_name_last() AS last_name,
        fakeit_contact_email() AS email,
        NULL::VARCHAR AS notes
    FROM range(95)
)
SELECT *
FROM fake_people
UNPIVOT INCLUDE NULLS (
    value FOR column_name IN (first_name, last_name, email, notes)
)
ORDER BY row_id, column_name;
```

Grain: one (row_id, column_name). Expected 95 × 4 = 380 cells including 95 NULL notes. Wrapping this SELECT in a CTE for inspection is enough: compare len(array_agg((row_id,column_name))) with len(array_agg(DISTINCT (row_id,column_name))). Keep the list evidence while diagnosing a duplicate; do not pick an arbitrary row with any_value, min, max, avg, or sum.

The local worked query is [staging_extensions_20260928.sql](/Users/aloksubbarao/.duck/staging_extensions_20260928.sql). On 2026-09-29 it generated organization/user/contact_person, 95 rows each: 1,615 / 950 / 1,425 cells. All source columns represented, no duplicate cells, required values present, and generated contact/user parent IDs resolved. It does not generate the other tables or certify all application constraints. Its Postgres database name is staging_extensions_20260928; AS staging defines the DuckDB alias; staging.public is the source schema, not dev.main.

## Use inference as evidence
FineType's installed ft_profile('staging.public.contact_person') already unpivots a bounded sample and returns one inferred label per populated column. It can misclassify, and all-NULL columns may be absent: anchor any schema join on duckdb_columns(), keep confidence, and use a left join for profiles. In this clone, title was classified as container.object.json_array; that does not make JSON the right job-title generator.

FakeIt provides value functions; inspect the installed signature before assuming dynamic generation. On 2026-09-29 fakeit_generator_generate had zero parameters despite upstream documentation showing a template argument. FineType's CLI/MCP generate capability is separate from the installed DuckDB functions. Never infer a DuckDB function exists from another interface's docs.

## Learn from sources, without copying scaffolding
- Closure samples/gen/corpus.sql: per-column generators and shared identity relationships; its tables and export steps are not required for the base SELECT.
- [Factory Boy](https://github.com/FactoryBoy/factory_boy): explicit field declarations and related factories.
- [Snowfakery](https://github.com/SFDO-Tooling/Snowfakery/blob/main/docs/index.md): declarative field recipes and object relationships.
Translate declarations into columns or keyed recipe rows, not procedural loops. A CASE expression is not inherently a lossy aggregation; the defects here were guessed semantics and a key-constraint join that multiplied columns. Correct the grain before generation.

Backend import counts from Fledgling measure code coupling, not production query frequency. Duck Hunt can parse supplied runtime/test logs; it cannot invent per-table traffic measurements. A restored local Postgres's scan counters are not production workload history.

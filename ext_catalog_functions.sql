-- Replay on the selected service after ext_catalog.sql; requires Webbed.
-- Documentation association, not definitive ownership of every runtime overload.
CREATE OR REPLACE VIEW agents.ext_function_docs AS
WITH blocks AS (
 SELECT extension_name, b.content
 FROM agents.ext_catalog
 CROSS JOIN UNNEST(html_to_duck_blocks((community->>'body')::HTML)) t(b)
 WHERE b.element_type = 'table'
), tables AS (
 SELECT extension_name,
 from_json(content, '{"headers":["VARCHAR"],"rows":[["VARCHAR"]]}') AS doc
 FROM blocks
)
SELECT DISTINCT extension_name,
 'https://duckdb.org/community_extensions/extensions/' || extension_name AS source_url,
 row[list_position(doc.headers,'function_name')] AS function_name,
 row[list_position(doc.headers,'function_type')] AS function_type,
 nullif(row[list_position(doc.headers,'description')], 'NULL') AS documented_description,
 row[list_position(doc.headers,'examples')] AS documented_examples
FROM tables CROSS JOIN UNNEST(doc.rows) t(row)
WHERE list_contains(doc.headers,'function_name')
 AND list_contains(doc.headers,'function_type');

CREATE OR REPLACE VIEW agents.ext_parameter_docs AS
WITH blocks AS (
 SELECT extension_name, b.element_order, b.content
 FROM agents.ext_docs
 CROSS JOIN UNNEST(parse_markdown_to_duck_blocks(readme)) t(b)
 WHERE b.element_type = 'table'
), tables AS (
 SELECT *, from_json(content, '{"headers":["VARCHAR"],"rows":[["VARCHAR"]]}') AS doc FROM blocks
), normalized AS (
 SELECT *, list_transform(doc.headers, h -> lower(h)) AS headers FROM tables
)
SELECT DISTINCT extension_name, element_order AS source_block,
 row[list_position(headers,'parameter')] AS parameter_name,
 row[list_position(headers,'description')] AS explanation,
 'extension README parameter table; function scope not inferred' AS documentation_scope
FROM normalized CROSS JOIN UNNEST(doc.rows) t(row)
WHERE list_contains(headers,'parameter') AND list_contains(headers,'description');
CREATE OR REPLACE VIEW agents.ext_function_signatures AS
WITH names AS (
 SELECT DISTINCT extension_name, source_url, function_name, function_type
 FROM agents.ext_function_docs
), parameter_docs AS (
 SELECT extension_name, array_agg({
 parameter_name: parameter_name, explanation: explanation,
 source_block: source_block, documentation_scope: documentation_scope
 }) AS entries FROM agents.ext_parameter_docs GROUP BY extension_name
)
SELECT n.*, 'community-documentation + runtime-name/type' AS association_basis,
 f.function_oid IS NOT NULL AS runtime_present,
 f.database_name, f.schema_name, f.function_oid,
 f.parameters, f.parameter_types, f.varargs, f.return_type,
 f.description AS runtime_description, f.examples AS runtime_examples,
 list_transform(f.parameters, p -> {
 name: p,
 documentation: nullif(list_filter(d.entries, e -> e.parameter_name = p), [])
 }) AS parameter_explanations
FROM names n LEFT JOIN duckdb_functions() f USING(function_name, function_type)
LEFT JOIN parameter_docs d USING(extension_name);

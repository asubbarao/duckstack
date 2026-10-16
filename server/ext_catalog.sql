-- ext_catalog: one row per community extension. Every source is a column, parsed in place:
--   description.yml -> yaml_to_json (yaml); community page function table -> html_to_duck_blocks (webbed);
--   GitHub README <article> -> markdown (webbed + markdown) and its SQL examples -> parse_function_names (parser_tools);
--   overloads come from duckdb_functions() for whatever is loaded. parser_tools reports scalar functions only, so
--   mentioned_functions also takes every loaded function the README names right before "(" (table functions too).
-- Raw pages are the newest 200 response per url in the fetch store; nothing here fetches.
CREATE SCHEMA IF NOT EXISTS agents;
CREATE OR REPLACE VIEW agents.ext_catalog AS
WITH page AS (
  SELECT url, fetched_at, response->>'body' AS body FROM lake.agents.ext_fetch
  WHERE try_cast(response->>'status' AS INTEGER) = 200
  QUALIFY row_number() OVER (PARTITION BY url ORDER BY fetched_at DESC) = 1
), yml AS (
  SELECT split_part(split_part(url, '/extensions/', 2), '/description.yml', 1) AS extension_name,
         yaml_to_json(body::yaml) AS description_yml, fetched_at
  FROM page WHERE ends_with(url, '/description.yml')
), joined AS (
  SELECT y.extension_name, y.description_yml,
         'https://github.com/' || (y.description_yml->>'$.repo.github') AS github_url,
         list_transform(list_filter(html_to_duck_blocks(c.body::HTML), b -> b.element_type = 'table'),
                        b -> from_json(b.content, '{"headers":["VARCHAR"],"rows":[["VARCHAR"]]}')) AS community_tables,
         list_filter(html_to_duck_blocks(xml_extract_elements(parse_html(g.body), '//article')[1]::VARCHAR),
                     b -> NOT coalesce(starts_with(b.attributes['id'], 'user-content-'), false)) AS readme_blocks,
         greatest(y.fetched_at, c.fetched_at, g.fetched_at) AS fetched_at
  FROM yml y
  LEFT JOIN page c ON c.url = 'https://duckdb.org/community_extensions/extensions/' || y.extension_name || '.html'
  LEFT JOIN page g ON g.url = 'https://github.com/' || (y.description_yml->>'$.repo.github')
), documented AS (
  SELECT j.extension_name, f.*
  FROM joined j CROSS JOIN UNNEST(flatten(list_transform(j.community_tables,
       d -> CASE WHEN list_contains(d.headers, 'function_name')
                 THEN list_transform(d.rows, r -> {
                        name: r[list_position(d.headers, 'function_name')],
                        kind: r[list_position(d.headers, 'function_type')],
                        description: nullif(r[list_position(d.headers, 'description')], 'NULL'),
                        examples: nullif(trim(r[list_position(d.headers, 'examples')]), '')})
                 ELSE [] END))) AS u(f)
), runtime AS (
  SELECT function_name, function_type,
         list({parameters: parameters, parameter_types: parameter_types, return_type: return_type, varargs: varargs}) AS overloads
  FROM duckdb_functions() GROUP BY ALL
), functions AS (
  SELECT d.extension_name,
         list({name: d.name, kind: d.kind, description: d.description, examples: d.examples, overloads: r.overloads}
              ORDER BY d.name, d.kind) AS functions
  FROM (SELECT DISTINCT * FROM documented) d
  LEFT JOIN runtime r ON r.function_name = d.name AND r.function_type = d.kind
  GROUP BY d.extension_name
), mentioned AS (
  SELECT w.extension_name,
         list({name: r.function_name, kind: r.function_type, overloads: r.overloads} ORDER BY r.function_name, r.function_type) AS mentioned_functions
  FROM (SELECT DISTINCT j.extension_name,
               string_split(replace(replace(replace(p, E'\n', ' '), '.', ' '), E'\t', ' '), ' ')[-1] AS word
        FROM joined j CROSS JOIN UNNEST(string_split(duck_blocks_to_md(j.readme_blocks), '(')) AS u(p)) w
  JOIN runtime r ON r.function_name = w.word
  GROUP BY w.extension_name
)
SELECT j.extension_name,
       j.description_yml->>'$.extension.description' AS description,
       j.description_yml->>'$.extension.version' AS version,
       j.description_yml->>'$.extension.language' AS language,
       j.description_yml->>'$.extension.license' AS license,
       j.github_url,
       j.description_yml->>'$.repo.ref' AS repo_ref,
       e.installed, e.loaded, e.extension_version AS installed_version,
       coalesce(f.functions, []) AS functions,
       duck_blocks_to_md(j.readme_blocks) AS readme,
       list_transform(list_filter(j.readme_blocks, b -> b.element_type = 'code' AND is_parsable(b.content)), b -> b.content) AS readme_sql,
       list_distinct(flatten(list_transform(
         list_filter(j.readme_blocks, b -> b.element_type = 'code' AND is_parsable(b.content)),
         b -> parse_function_names(b.content)))) AS readme_functions,
       coalesce(m.mentioned_functions, []) AS mentioned_functions,
       j.description_yml,
       j.fetched_at
FROM joined j
LEFT JOIN functions f USING (extension_name)
LEFT JOIN mentioned m USING (extension_name)
LEFT JOIN duckdb_extensions() e USING (extension_name);

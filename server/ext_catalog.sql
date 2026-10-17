-- agents.ext_catalog: one row per community extension, each source a typed column: yml (description.yml), page (the
-- community page, HTML) and readme (the GitHub README, markdown), with functions and readme_functions parsed from them,
-- each function carrying its overloads from duckdb_functions() when its extension is loaded.
-- Every 30 minutes one statement rebuilds it. calls declares the previous rows' query it dispatches.
-- The list page gives the extensions; each (extension, source) URL renders the tera skill's fetch_shellfs.tera and is
-- self-dispatched, so a missing or rate-limited URL fails alone; the bodies are parsed here. READMEs are rate-limited by
-- GitHub, so one is fetched only when the previous row has none from the last day; on a fresh dev the previous-rows
-- query fails and yields none.
CREATE SCHEMA IF NOT EXISTS agents;
DROP VIEW IF EXISTS agents.ext_catalog;
DROP VIEW IF EXISTS agents.ext_docs;
SELECT cron($$
CREATE OR REPLACE TABLE agents.ext_catalog AS
WITH calls AS (
    SELECT 'SELECT extension_name, readme::VARCHAR AS readme, fetched_at FROM agents.ext_catalog WHERE readme IS NOT NULL' AS previous_sql
), links AS (
    SELECT i, url_resolve('https://duckdb.org/community_extensions/list_of_extensions', l.href) AS url, l.text
    FROM read_html_objects('https://duckdb.org/community_extensions/list_of_extensions')
    CROSS JOIN UNNEST(html_extract_links(html)) WITH ORDINALITY AS u(l, i)
), ext AS (
    SELECT urlpattern_extract('https://duckdb.org/community_extensions/extensions/:name.html', n.url, 'name') AS extension_name,
           'https://raw.githubusercontent.com/duckdb/community-extensions/main/extensions/' || extension_name || '/description.yml' AS yml,
           n.url AS page, g.url AS readme
    FROM links n JOIN links g ON g.i = n.i + 1 AND g.text = 'GitHub'
    WHERE urlpattern_test('https://duckdb.org/community_extensions/extensions/:name.html', n.url)
), previous AS (
    SELECT o.* FROM (SELECT array_agg(selfdispatch(previous_sql)) AS receipts FROM calls)
    CROSS JOIN UNNEST(receipts) AS t(r)
    CROSS JOIN UNNEST(from_json(r.body, '[{"extension_name": "VARCHAR", "readme": "VARCHAR", "fetched_at": "TIMESTAMPTZ"}]')) AS b(o)
    WHERE r.status = 200
), rendered AS (
    SELECT extension_name, kind,
           tera_render('fetch_shellfs.tera', json_object('url', url, 'user_agent', 'duckstack-ext-catalog/1.0', 'timeout', 30, 'max_bytes', 20000000, 'headers', [], 'params', []), autoescape := false,
                       template_path := getenv('HOME') || '/.duck/deploy/skills/tera/references/*.tera') AS sql
    FROM (UNPIVOT ext ON yml, page, readme INTO NAME kind VALUE url)
    ANTI JOIN (SELECT extension_name, 'readme' AS kind FROM previous WHERE fetched_at > now() - INTERVAL 1 DAY) USING (extension_name, kind)
), posted AS (
    SELECT array_agg({'extension_name': extension_name, 'kind': kind, 'receipt': selfdispatch(sql)}) AS receipts FROM rendered
), fresh AS (
    PIVOT (SELECT p.extension_name, p.kind, json_extract_string(p.receipt.body, '$[0].body') AS body
           FROM posted CROSS JOIN UNNEST(receipts) AS t(p) WHERE p.receipt.status = 200)
    ON kind IN ('yml', 'page', 'readme') USING max(body)
), merged AS (
    SELECT extension_name, yaml_to_json(fresh.yml::YAML)::JSON AS yml, fresh.page::HTML AS page,
           coalesce(nullif(duck_blocks_to_md(html_to_duck_blocks(xml_extract_elements(parse_html(fresh.readme), '//article')[1]::VARCHAR)), ''),
                    previous.readme)::md AS readme,
           CASE WHEN fresh.readme IS NOT NULL THEN now() ELSE previous.fetched_at END AS fetched_at
    FROM fresh LEFT JOIN previous USING (extension_name)
), parsed AS (
    SELECT merged.*,
           flatten(list_transform(list_filter(html_extract_tables_json(page), lambda t: list_contains(t.headers, 'function_name')), lambda t:
               list_transform(t.table_data, lambda r: {name: r[list_position(t.headers, 'function_name')], kind: r[list_position(t.headers, 'function_type')],
                                                       description: r[list_position(t.headers, 'description')], examples: r[list_position(t.headers, 'examples')]}))) AS page_functions,
           list_distinct(flatten(list_transform(md_extract_code_blocks(readme), lambda b:
               list_transform(list_filter(parse_ast_list(b.code, 'sql'), lambda n: n.type = 'invocation'), lambda n: lower(n.name))))) AS readme_names
    FROM merged
), signatures AS (
    SELECT function_name, list({kind: function_type, parameters: parameters, parameter_types: parameter_types, return_type: return_type}) AS overloads
    FROM duckdb_functions() GROUP BY function_name
), functions AS (
    SELECT p.extension_name, list({name: f.name, kind: f.kind, description: f.description, examples: f.examples, overloads: s.overloads} ORDER BY f.name) AS functions
    FROM parsed p CROSS JOIN UNNEST(p.page_functions) AS t(f) LEFT JOIN signatures s ON s.function_name = f.name GROUP BY p.extension_name
), readme_functions AS (
    SELECT p.extension_name, list({name: n, overloads: s.overloads} ORDER BY n) AS readme_functions
    FROM parsed p CROSS JOIN UNNEST(p.readme_names) AS t(n) LEFT JOIN signatures s ON s.function_name = n GROUP BY p.extension_name
)
SELECT parsed.* EXCLUDE (page_functions, readme_names), functions.functions, readme_functions.readme_functions,
       e.installed, e.loaded, e.extension_version AS installed_version
FROM parsed LEFT JOIN functions USING (extension_name) LEFT JOIN readme_functions USING (extension_name)
LEFT JOIN duckdb_extensions() e USING (extension_name)
$$, '0 */30 * * * *');

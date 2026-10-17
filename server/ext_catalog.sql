-- agents.ext_catalog: one row per community extension, each source a typed column: yml (description.yml), page (the
-- community page, HTML) and readme (the GitHub README, markdown), with functions and readme_functions parsed from them.
-- Every 30 minutes one statement rebuilds it from the list page. Each URL is read by its own dispatched statement, so a
-- missing or rate-limited URL fails alone. GitHub rate-limits, so READMEs are fetched only for extensions without one
-- from the last day, and the rest carry over: the previous rows are read through a dispatch too, so on a fresh dev that
-- read fails, yields no rows, and every README is due.
CREATE SCHEMA IF NOT EXISTS agents;
DROP VIEW IF EXISTS agents.ext_catalog;
DROP VIEW IF EXISTS agents.ext_docs;
SELECT cron($$
CREATE OR REPLACE TABLE agents.ext_catalog AS
WITH links AS (
    SELECT i, url_resolve('https://duckdb.org/community_extensions/list_of_extensions', l.href) AS url, l.text
    FROM read_html_objects('https://duckdb.org/community_extensions/list_of_extensions')
    CROSS JOIN UNNEST(html_extract_links(html)) WITH ORDINALITY AS u(l, i)
), ext AS (
    SELECT urlpattern_extract('https://duckdb.org/community_extensions/extensions/:name.html', n.url, 'name') AS extension_name,
           n.url AS page_url, g.url AS repo_url
    FROM links n JOIN links g ON g.i = n.i + 1 AND g.text = 'GitHub'
    WHERE urlpattern_test('https://duckdb.org/community_extensions/extensions/:name.html', n.url)
), old AS (
    SELECT o.* FROM (SELECT selfdispatch('SELECT extension_name, readme::VARCHAR AS readme, fetched_at FROM agents.ext_catalog WHERE readme IS NOT NULL') AS r)
    CROSS JOIN UNNEST(from_json(r.body, '[{"extension_name": "VARCHAR", "readme": "VARCHAR", "fetched_at": "TIMESTAMPTZ"}]')) AS t(o)
    WHERE r.status = 200
), jobs AS (
    SELECT extension_name, 'yml' AS kind, 'SELECT to_json(y)::VARCHAR AS v FROM read_yaml(' || quote_literal('https://raw.githubusercontent.com/duckdb/community-extensions/main/extensions/' || extension_name || '/description.yml') || ') y' AS sql FROM ext
    UNION ALL SELECT extension_name, 'page', 'SELECT html::VARCHAR AS v FROM read_html_objects(' || quote_literal(page_url) || ')' FROM ext
    UNION ALL SELECT extension_name, 'readme', 'SELECT duck_blocks_to_md(html_to_duck_blocks(xml_extract_elements(parse_html(html::VARCHAR), $x$//article$x$)[1]::VARCHAR))::VARCHAR AS v FROM read_html_objects(' || quote_literal(repo_url) || ')'
    FROM ext ANTI JOIN (FROM old WHERE fetched_at > now() - INTERVAL 1 DAY) USING (extension_name)
), fresh AS (
    PIVOT (SELECT extension_name, kind, json_extract_string(r.body, '$[0].v') AS v FROM (SELECT extension_name, kind, selfdispatch(sql) AS r FROM jobs) WHERE r.status = 200)
    ON kind IN ('yml', 'page', 'readme') USING max(v)
), merged AS (
    SELECT extension_name, fresh.yml::JSON AS yml, fresh.page::HTML AS page,
           coalesce(nullif(fresh.readme, ''), old.readme)::md AS readme,
           CASE WHEN nullif(fresh.readme, '') IS NOT NULL THEN now() ELSE old.fetched_at END AS fetched_at
    FROM fresh LEFT JOIN old USING (extension_name)
)
SELECT merged.*,
       flatten(list_transform(list_filter(html_extract_tables_json(page), lambda t: list_contains(t.headers, 'function_name')), lambda t:
           list_transform(t.table_data, lambda r: {name: r[list_position(t.headers, 'function_name')], kind: r[list_position(t.headers, 'function_type')],
                                                   description: r[list_position(t.headers, 'description')], examples: r[list_position(t.headers, 'examples')]}))) AS functions,
       list_distinct(flatten(list_transform(md_extract_code_blocks(readme), lambda b:
           list_transform(list_filter(parse_ast_list(b.code, 'sql'), lambda n: n.type = 'invocation'), lambda n: lower(n.name))))) AS readme_functions,
       e.installed, e.loaded, e.extension_version AS installed_version
FROM merged LEFT JOIN duckdb_extensions() e USING (extension_name)
$$, '0 */30 * * * *');

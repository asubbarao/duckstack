-- agents.ext_catalog joins latest successful description.yml, HTML tables and GitHub README fetches.
-- Refresh missing/day-old pages, descriptions and repositories daily.
-- Both boot statements self-dispatch so a lake failure stays a receipt and dev keeps serving.
CREATE SCHEMA IF NOT EXISTS agents;
WITH program AS (
    SELECT 'view' AS step, $v$CREATE OR REPLACE VIEW agents.ext_catalog AS
WITH newest AS (
    SELECT url, arg_max(response ->> 'body', fetched_at) AS body FROM lake.agents.ext_fetch WHERE response ->> 'status' = '200' GROUP BY url
), yml AS (
    SELECT urlpattern_extract('https://raw.githubusercontent.com/duckdb/community-extensions/main/extensions/:name/description.yml', url, 'name') AS extension_name,
           yaml_to_json(body::YAML) AS yml
    FROM newest WHERE urlpattern_test('https://raw.githubusercontent.com/duckdb/community-extensions/main/extensions/:name/description.yml', url)
), page AS (
    SELECT urlpattern_extract('https://duckdb.org/community_extensions/extensions/:name.html', url, 'name') AS extension_name, body::HTML AS page
    FROM newest WHERE urlpattern_test('https://duckdb.org/community_extensions/extensions/:name.html', url)
), readme AS (
    SELECT url, duck_blocks_to_md(html_to_duck_blocks(xml_extract_elements(parse_html(body), '//article')[1]::VARCHAR))::md AS readme
    FROM newest WHERE starts_with(url, 'https://github.com/')
)
SELECT extension_name, yml, page, html_extract_tables_json(page) AS functions, readme.readme
FROM yml FULL JOIN page USING (extension_name) LEFT JOIN readme ON ltrim(url_parse(readme.url).pathname, '/') = (yml ->> '$.repo.github')$v$ AS sql
    UNION ALL
    SELECT 'refresh', $r$INSERT INTO lake.agents.ext_fetch BY NAME
WITH links AS (
    SELECT l.*, 'https://duckdb.org/community_extensions/extensions/:name.html' AS page_pattern,
           'https://raw.githubusercontent.com/duckdb/community-extensions/main/extensions/{{ name }}/description.yml' AS description_template,
           urlpattern_extract(page_pattern, l.url, 'name') AS name
    FROM web_page('https://duckdb.org/community_extensions/list_of_extensions') AS p CROSS JOIN UNNEST(p.links) AS t(l)
    WHERE p.status = 200
), urls AS (
    SELECT unnest([url, tera_render(description_template, l::JSON, autoescape := false)]) AS url
    FROM links AS l WHERE name IS NOT NULL
    UNION ALL SELECT url FROM links WHERE text = 'GitHub'
)
SELECT url, now() AS fetched_at, to_json(quackapi_fetch(url)) AS response
FROM urls ANTI JOIN (FROM lake.agents.ext_fetch WHERE fetched_at > now() - INTERVAL 1 DAY) USING (url)$r$
), posted AS (
    SELECT step, sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY ALL
)
SELECT step, CASE step WHEN 'refresh' THEN cron(sql, '0 0 4 * * *') END AS job, r.status FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

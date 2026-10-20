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
WITH intent AS (
    SELECT 'https://duckdb.org/community_extensions/extensions/:name.html' AS page_pattern,
           'https://raw.githubusercontent.com/duckdb/community-extensions/main/extensions/{{ name }}/description.yml' AS description_template,
           links FROM web_page('https://duckdb.org/community_extensions/list_of_extensions') WHERE status = 200
), links AS (
    SELECT l.*, page_pattern, description_template, urlpattern_extract(page_pattern, l.url, 'name') AS name
    FROM intent CROSS JOIN UNNEST(links) AS t(l)
), urls AS (
    SELECT unnest([url, tera_render(description_template, l::JSON, autoescape := false)]) AS url
    FROM links AS l WHERE name IS NOT NULL
    UNION ALL SELECT url FROM links WHERE text = 'GitHub'
), atoms AS (
    SELECT url, 'SELECT response FROM web_page(' || quote_literal(url) || ')' AS sql
    FROM urls ANTI JOIN (FROM lake.agents.ext_fetch WHERE fetched_at > now() - INTERVAL 1 DAY) USING (url)
), fetched AS (
    SELECT url, array_agg(selfdispatch(sql)) AS arr FROM atoms GROUP BY url
)
SELECT url, now() AS fetched_at, coalesce(try_cast(page ->> 'response' AS JSON), to_json(receipt)) AS response
FROM fetched CROSS JOIN UNNEST(arr) AS t(receipt)
CROSS JOIN UNNEST(coalesce(try_cast(receipt.body AS JSON[]), [NULL])) AS p(page)$r$
), posted AS (
    SELECT step, sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY ALL
)
SELECT step, CASE step WHEN 'refresh' THEN cron(sql, '0 0 4 * * *') END AS job, r.status FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

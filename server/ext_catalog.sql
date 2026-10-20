-- Raw observations stay in ext_fetch; the catalogue selects the latest successful response.
-- One index plus missing/day-old targets; native fetch: 30s, 16 MiB, no retries or extra workers.
-- Link following is index -> named targets only (depth 1); targets are bounded by its distinct URL set.
CREATE SCHEMA IF NOT EXISTS agents;
CREATE OR REPLACE VIEW agents.ext_url_patterns AS
SELECT 'https://duckdb.org/community_extensions/extensions/:name.html' AS page_pattern,
       'https://raw.githubusercontent.com/duckdb/community-extensions/main/extensions/:name/description.yml' AS description_pattern;
WITH program AS (
    SELECT 'view' AS step, $v$CREATE OR REPLACE VIEW agents.ext_catalog AS
WITH newest AS (
    SELECT url, arg_max(response ->> 'body', fetched_at) AS body
    FROM lake.agents.ext_fetch WHERE response ->> 'status' = '200' GROUP BY url
), yml AS (
    SELECT urlpattern_extract(description_pattern, url, 'name') AS extension_name, yaml_to_json(body::YAML) AS yml
    FROM newest JOIN agents.ext_url_patterns ON urlpattern_test(description_pattern, url)
), page AS (
    SELECT urlpattern_extract(page_pattern, url, 'name') AS extension_name, body::HTML AS page
    FROM newest JOIN agents.ext_url_patterns ON urlpattern_test(page_pattern, url)
), readme AS (
    SELECT url, duck_blocks_to_md(html_to_duck_blocks(xml_extract_elements(parse_html(body), '//article')[1]::VARCHAR))::md AS readme
    FROM newest WHERE starts_with(url, 'https://github.com/')
)
SELECT extension_name, yml, page, html_extract_tables_json(page) AS functions, readme.readme
FROM yml FULL JOIN page USING (extension_name) LEFT JOIN readme ON ltrim(url_parse(readme.url).pathname, '/') = (yml ->> '$.repo.github')$v$ AS executable_sql
    UNION ALL
    SELECT 'refresh', $r$WITH index_statements AS (
    SELECT 'https://duckdb.org/community_extensions/list_of_extensions' AS url,
           'INSERT INTO lake.agents.ext_fetch BY NAME SELECT requested_url AS url, now() AS fetched_at, response FROM web_page({{ literal }})' AS insert_template,
           quote_literal(url) AS literal,
           tera_render(insert_template, {literal: literal}::JSON, autoescape := false) AS executable_sql,
           tera_render($read$WITH cached AS (
               SELECT url, arg_max(response, fetched_at) AS response
               FROM lake.agents.ext_fetch WHERE url = {{ literal }} GROUP BY url
           )
           SELECT url, response ->> 'status' AS status, response ->> 'error' AS error,
                  list_transform(html_extract_links(CASE WHEN contains(lower(jsonata(
                      '$lookup(headers, $keys(headers)[$lowercase($) = "content-type"])', response)::VARCHAR), 'html')
                      THEN (response ->> 'body')::HTML END),
                      link -> struct_insert(link, url := url_resolve(
                          coalesce(response ->> 'url_effective', response ->> 'url', url), link.href))) AS links
           FROM cached$read$, {literal: literal}::JSON, autoescape := false) AS read_sql
), index_posts AS (
    SELECT *, array_agg(selfdispatch(executable_sql)) AS arr FROM index_statements GROUP BY ALL
), index_read_posts AS (
    SELECT source.* EXCLUDE(arr), receipt AS write_receipt, array_agg(selfdispatch(read_sql)) AS arr
    FROM index_posts AS source CROSS JOIN UNNEST(arr) AS t(receipt)
    WHERE receipt.error IS NULL GROUP BY ALL
), index_pages AS (
    SELECT source.* EXCLUDE(arr), receipt, page ->> 'status' AS page_status, page ->> 'error' AS page_error, page -> '$.links[*]' AS links
    FROM index_read_posts AS source CROSS JOIN UNNEST(arr) AS t(receipt)
    CROSS JOIN UNNEST(coalesce(try_cast(receipt.body AS JSON[]), [NULL])) AS p(page)
), index_links AS (
    SELECT insert_template, link ->> 'url' AS url, link ->> 'text' AS text
    FROM index_pages CROSS JOIN UNNEST(links) AS t(link) WHERE page_status = '200'
), target_urls AS (
    SELECT insert_template, urlpattern_extract(page_pattern, index_links.url, 'name') AS name,
           unnest([replace(page_pattern, ':name', name), replace(description_pattern, ':name', name)]) AS url
    FROM index_links JOIN agents.ext_url_patterns ON urlpattern_test(page_pattern, index_links.url)
    UNION ALL BY NAME SELECT insert_template, url FROM index_links WHERE text = 'GitHub'
), page_statements AS (
    SELECT DISTINCT insert_template, url, quote_literal(url) AS literal,
           tera_render(insert_template, {literal: literal}::JSON, autoescape := false) AS executable_sql
    FROM target_urls ANTI JOIN (FROM lake.agents.ext_fetch WHERE fetched_at > now() - INTERVAL 1 DAY) USING (url)
), page_posts AS (
    SELECT *, array_agg(selfdispatch(executable_sql)) AS arr FROM page_statements GROUP BY ALL
)
SELECT 'index_write' AS stage, source.url, source.executable_sql, receipt.*
FROM index_posts AS source CROSS JOIN UNNEST(arr) AS t(receipt)
UNION ALL BY NAME
SELECT 'index_read' AS stage, url, read_sql AS executable_sql, receipt.status, receipt.error, page_status, page_error
FROM index_pages
UNION ALL BY NAME
SELECT 'page_write' AS stage, source.url, source.executable_sql, receipt.*
FROM page_posts AS source CROSS JOIN UNNEST(arr) AS t(receipt)$r$
), posted AS (
    SELECT *, array_agg(selfdispatch(executable_sql)) AS arr FROM program GROUP BY ALL
)
SELECT source.step, source.executable_sql,
       CASE step WHEN 'refresh' THEN cron(executable_sql, '0 0 4 * * *') END AS job, receipt.*
FROM posted AS source CROSS JOIN UNNEST(arr) AS t(receipt);

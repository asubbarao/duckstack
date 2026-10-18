-- agents.ext_catalog: one row per community extension, from the newest fetches in lake.agents.ext_fetch: yml
-- (description.yml), page (the community page as HTML), functions (its tables) and readme (the GitHub README as
-- markdown). Agents query it; nobody fetches docs. The refresh fetches, with quackapi_fetch, every page, description.yml
-- and repo the list page names that has no fetch from the last day. Both statements are self-dispatched at boot, so a
-- lake failure is a failed receipt and dev keeps serving; the refresh also runs daily.
CREATE SCHEMA IF NOT EXISTS agents;
-- The lake starts empty on a fresh machine (or CI's empty HOME); the view and the refresh below both read and
-- write lake.agents.ext_fetch, so the table must exist before the dispatched program runs. No-op where it exists.
CREATE SCHEMA IF NOT EXISTS lake.agents;
CREATE TABLE IF NOT EXISTS lake.agents.ext_fetch (url VARCHAR, fetched_at TIMESTAMPTZ, response JSON);
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
    SELECT url_resolve('https://duckdb.org/community_extensions/list_of_extensions', l.href) AS url, l.text
    FROM read_html_objects('https://duckdb.org/community_extensions/list_of_extensions') CROSS JOIN UNNEST(html_extract_links(html)) AS u(l)
), pages AS (
    SELECT url, urlpattern_extract('https://duckdb.org/community_extensions/extensions/:name.html', url, 'name') AS name
    FROM links WHERE urlpattern_test('https://duckdb.org/community_extensions/extensions/:name.html', url)
), urls AS (
    SELECT url FROM pages
    UNION ALL SELECT tera_render('https://raw.githubusercontent.com/duckdb/community-extensions/main/extensions/{{ name }}/description.yml', p::JSON, autoescape := false) FROM pages AS p
    UNION ALL SELECT url FROM links WHERE text = 'GitHub'
)
SELECT url, now() AS fetched_at, to_json(quackapi_fetch(url)) AS response
FROM urls ANTI JOIN (FROM lake.agents.ext_fetch WHERE fetched_at > now() - INTERVAL 1 DAY) USING (url)$r$
), posted AS (
    SELECT step, sql, array_agg(selfdispatch(sql)) AS receipts FROM program GROUP BY ALL
)
SELECT step, CASE step WHEN 'refresh' THEN cron(sql, '0 0 4 * * *') END AS job, r.status FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

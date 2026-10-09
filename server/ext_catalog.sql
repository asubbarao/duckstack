-- ext_catalog. Raw first: ext_page retains the raw document and crawler receipt (grain: url). The rest are views:
-- ext_url reads each extension's community page, GitHub repo and description.yml off the community list page (webbed links),
-- ext_catalog PIVOTs the raw responses to one row per extension, ext_docs is the README: the GitHub <article>, parsed by webbed.
-- A page is fetched only when missing or older than three days; clear lake.agents.ext_page to rebuild everything.
-- Bootstrap attaches lake and prepares lake.agents plus the read-only agents.* compatibility views.
LOAD http_client; LOAD webbed; LOAD markdown;
CREATE TABLE IF NOT EXISTS lake.agents.ext_page (url VARCHAR, fetched_at TIMESTAMPTZ, response JSON);
CREATE TABLE IF NOT EXISTS lake.agents.ext_fetch (url VARCHAR, fetched_at TIMESTAMPTZ, response JSON);
CREATE OR REPLACE VIEW agents.ext_url AS
WITH link AS (
    SELECT unnest(l, recursive := true), generate_subscripts(l, 1) AS i
    FROM (SELECT html_extract_links(parse_html(response->>'body')) AS l FROM agents.ext_page
          WHERE url = 'https://duckdb.org/community_extensions/list_of_extensions')
), ext AS (  -- a row of the list's table (nanoarrow is listed twice): the name links to the community page, the link after it is its GitHub repo
    SELECT DISTINCT n.text AS extension_name, 'https://duckdb.org' || n.href AS community, g.href AS github,
           format('https://raw.githubusercontent.com/duckdb/community-extensions/main/extensions/{}/description.yml', n.text) AS yaml
    FROM link n JOIN link g ON g.i = n.i + 1 AND g.text = 'GitHub'
)
UNPIVOT ext ON community, github, yaml INTO NAME kind VALUE url;
CREATE OR REPLACE VIEW agents.ext_stale AS
FROM (SELECT 'list' AS kind, 'https://duckdb.org/community_extensions/list_of_extensions' AS url UNION ALL BY NAME FROM agents.ext_url)
ANTI JOIN (FROM agents.ext_page WHERE fetched_at > now() - INTERVAL 3 DAY
           AND try_cast(response->>'status' AS INTEGER) = 200) USING (url)
ANTI JOIN (FROM agents.ext_fetch WHERE fetched_at > now() - INTERVAL 5 MINUTE) USING (url);
-- Six HTTP workers hydrate a cold catalog in bounded 90-page minute batches.
-- No link following or crawler cache: the raw document and receipt stay in ext_fetch.
SET VARIABLE ext_due_urls = (SELECT list(url ORDER BY kind = 'list' DESC, url)
 FROM (SELECT url,min(kind) AS kind FROM agents.ext_stale GROUP BY url
 ORDER BY min(kind) = 'list' DESC,url LIMIT 90));
MERGE INTO lake.agents.ext_fetch AS target
USING (
SELECT url, now() AS fetched_at,
 json_object('status',status,'body',html.document,'error',error,
 'content_type',content_type,'response_time_ms',response_time_ms) AS response
FROM crawl(coalesce(getvariable('ext_due_urls'), []::VARCHAR[]),
 workers := 6, batch_size := 6, timeout := 15000, delay := 0,
 follow := 'none', max_depth := 0, cache := false, max_results := 90)
QUALIFY row_number() OVER(PARTITION BY url ORDER BY response_time_ms)=1
) AS incoming ON target.url = incoming.url
WHEN MATCHED AND (target.fetched_at, target.response)
    IS DISTINCT FROM (incoming.fetched_at, incoming.response) THEN
    UPDATE SET fetched_at = incoming.fetched_at, response = incoming.response
WHEN NOT MATCHED THEN INSERT BY NAME;
MERGE INTO lake.agents.ext_page AS target
USING (
SELECT f.* FROM agents.ext_fetch f
LEFT JOIN agents.ext_page p USING (url)
WHERE try_cast(f.response->>'status' AS INTEGER) = 200
  AND f.fetched_at IS DISTINCT FROM p.fetched_at
) AS incoming ON target.url = incoming.url
WHEN MATCHED THEN UPDATE SET fetched_at = incoming.fetched_at, response = incoming.response
WHEN NOT MATCHED THEN INSERT BY NAME;
CREATE OR REPLACE VIEW agents.ext_fetch_errors AS
FROM agents.ext_fetch WHERE try_cast(response->>'status' AS INTEGER) IS DISTINCT FROM 200;
CREATE OR REPLACE VIEW agents.ext_catalog AS  -- ext_url has one url per (extension, kind), so each cell aggregates exactly one response
PIVOT (FROM agents.ext_url JOIN agents.ext_page USING (url)) ON kind IN ('community', 'github', 'yaml') USING any_value(response) GROUP BY extension_name;
CREATE OR REPLACE VIEW agents.ext_docs AS  -- GitHub's heading permalinks (id user-content-*) are page chrome, not README
SELECT extension_name, duck_blocks_to_md(list_filter(html_to_duck_blocks(xml_extract_elements(parse_html(github->>'body'), '//article')[1]::VARCHAR),
                                                     b -> NOT coalesce(starts_with(b.attributes['id'], 'user-content-'), false))) AS readme
FROM agents.ext_catalog;

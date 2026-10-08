-- Joinable upstream documentation, separate from the README/community catalog.
-- Bootstrap attaches lake and prepares lake.agents plus the read-only agents.* compatibility views.
-- Run on the selected service. Raw receipts are retained; fetch at most 3 due pages/run.
-- Re-run to follow discovered same-site links. Fragments are indexed, never fetched separately.
-- No recursive crawler: http_client fetches known URLs; webbed discovers HTML navigation;
-- Markdown is requested independently for compact page content. Not a 500-ms SLA.
INSTALL http_client FROM community; LOAD http_client;
INSTALL webbed FROM community; LOAD webbed;
INSTALL markdown FROM community; LOAD markdown;
CREATE SCHEMA IF NOT EXISTS agents;
CREATE TABLE IF NOT EXISTS lake.agents.ext_doc_source (
    extension_name VARCHAR, doc_url VARCHAR
);
MERGE INTO lake.agents.ext_doc_source AS target
USING (
SELECT 'duck_hunt' AS extension_name, 'https://duck-hunt.readthedocs.io/en/latest/' AS doc_url
UNION ALL SELECT 'duck_tails', 'https://duck-tails.readthedocs.io/en/latest/'
UNION ALL SELECT 'sitting_duck', 'https://sitting-duck.readthedocs.io/en/latest/'
) AS incoming ON target.extension_name = incoming.extension_name AND target.doc_url = incoming.doc_url
WHEN NOT MATCHED THEN INSERT BY NAME;
CREATE TABLE IF NOT EXISTS lake.agents.ext_doc_fetch (
    url VARCHAR, representation VARCHAR, fetched_at TIMESTAMPTZ, response JSON
);
CREATE TABLE IF NOT EXISTS lake.agents.ext_doc_page (
    url VARCHAR, representation VARCHAR, fetched_at TIMESTAMPTZ, response JSON
);
CREATE OR REPLACE VIEW agents.ext_doc_links AS
WITH links AS (
    SELECT s.extension_name, s.doc_url, p.url AS source_url, link.text AS raw_label,
           array_to_string(list_transform(list_filter(string_split(link.text, chr(10)),
               line -> trim(line) <> ''), line -> trim(line)), ' ') AS label,
           url_resolve(p.url, link.href) AS target_url
    FROM agents.ext_doc_source s JOIN agents.ext_doc_page p
      ON starts_with(p.url, s.doc_url) AND p.representation = 'html'
    CROSS JOIN UNNEST(html_extract_links((p.response->>'body')::HTML)) t(link)
), addresses AS (
    SELECT *, url_parse(target_url) AS parsed FROM links
)
SELECT DISTINCT extension_name, source_url, label, raw_label, target_url,
       left(target_url, len(target_url) - len(parsed.hash)) AS page_url,
       nullif(parsed.hash, '') AS fragment
FROM addresses WHERE starts_with(page_url, doc_url) AND label <> '';
CREATE OR REPLACE VIEW agents.ext_doc_due AS
WITH wanted AS (
    SELECT doc_url AS url FROM agents.ext_doc_source
    UNION SELECT page_url FROM agents.ext_doc_links
), representations AS (
    SELECT url, unnest(['html', 'markdown']) AS representation FROM wanted
)
SELECT r.* FROM representations r
ANTI JOIN (FROM agents.ext_doc_page WHERE fetched_at > now() - INTERVAL 3 DAY) p
USING (url, representation)
ANTI JOIN (FROM agents.ext_doc_fetch WHERE fetched_at > now() - INTERVAL 5 MINUTE) f
USING (url, representation);
MERGE INTO lake.agents.ext_doc_fetch AS target
USING (
SELECT url, representation, now() AS fetched_at,
       http_get(url, MAP {'Accept': 'text/' || representation}, MAP {'timeout':'10'}) AS response
FROM (FROM agents.ext_doc_due
      ORDER BY url IN (SELECT doc_url FROM agents.ext_doc_source) DESC, url, representation LIMIT 3)
) AS incoming ON target.url = incoming.url AND target.representation = incoming.representation
WHEN MATCHED AND (target.fetched_at, target.response)
    IS DISTINCT FROM (incoming.fetched_at, incoming.response) THEN
    UPDATE SET fetched_at = incoming.fetched_at, response = incoming.response
WHEN NOT MATCHED THEN INSERT BY NAME;
MERGE INTO lake.agents.ext_doc_page AS target
USING (
SELECT * FROM agents.ext_doc_fetch WHERE try_cast(response->>'status' AS INTEGER) = 200
) AS incoming ON target.url = incoming.url AND target.representation = incoming.representation
WHEN MATCHED AND (target.fetched_at, target.response)
    IS DISTINCT FROM (incoming.fetched_at, incoming.response) THEN
    UPDATE SET fetched_at = incoming.fetched_at, response = incoming.response
WHEN NOT MATCHED THEN INSERT BY NAME;
CREATE OR REPLACE VIEW agents.ext_doc_errors AS
FROM agents.ext_doc_fetch WHERE try_cast(response->>'status' AS INTEGER) IS DISTINCT FROM 200;
CREATE OR REPLACE VIEW agents.ext_doc_content AS
SELECT s.extension_name, p.*, p.response->>'body' AS content
FROM agents.ext_doc_source s JOIN agents.ext_doc_page p ON starts_with(p.url, s.doc_url);
CREATE OR REPLACE VIEW agents.ext_doc_blocks AS
SELECT c.extension_name, c.url, c.representation, b.*
FROM agents.ext_doc_content c
CROSS JOIN UNNEST(CASE WHEN representation = 'html' THEN html_to_duck_blocks(content::HTML)
                      ELSE parse_markdown_to_duck_blocks(content) END) t(b);
-- One cached document -> heading IDs -> section intervals -> rendered sections.
-- Fragments are downstream filters, not HTTP requests. Keep the original block structs.
CREATE OR REPLACE VIEW agents.ext_doc_sections AS
WITH blocks AS (
    SELECT c.extension_name, c.url, b AS block
    FROM agents.ext_doc_content c
    CROSS JOIN UNNEST(html_to_duck_blocks(content::HTML)) t(b)
    WHERE representation = 'html'
), headings AS (
    SELECT extension_name, url, '#' || block.attributes['id'] AS fragment,
           block.element_order AS start_order, block.level AS nesting_depth,
           try_cast(block.attributes['heading_level'] AS INTEGER) AS heading_level
    FROM blocks
    WHERE block.element_type = 'heading' AND block.attributes['id'] IS NOT NULL
), endings AS (
    -- A section includes subheadings until the next heading of equal/lower rank.
    SELECT h.url, h.start_order, n.start_order AS end_order
    FROM headings h JOIN headings n ON h.url = n.url
      AND n.start_order > h.start_order AND n.heading_level <= h.heading_level
    UNION ALL
    -- Stop at the enclosing container's end too: exclude footers/navigation.
    -- block.level is nesting depth, NOT heading rank.
    SELECT h.url, h.start_order, b.block.element_order AS end_order
    FROM headings h JOIN blocks b ON h.url = b.url
      AND b.block.element_order > h.start_order AND b.block.level < h.nesting_depth
), boundaries AS (
    SELECT h.*, min(e.end_order) AS end_order
    FROM headings h LEFT JOIN endings e USING (url, start_order)
    GROUP BY ALL
), sections AS (
    SELECT h.*, array_agg(b.block ORDER BY b.block.element_order) AS blocks
    FROM boundaries h JOIN blocks b ON h.url = b.url
      AND b.block.element_order >= h.start_order
      AND b.block.element_order < coalesce(h.end_order, 2147483647)
    GROUP BY ALL
)
SELECT extension_name, url, fragment, url || fragment AS section_url,
       heading_level, start_order, end_order, blocks, len(blocks) AS block_count,
       duck_blocks_to_html(blocks) AS html, duck_blocks_to_md(blocks) AS markdown,
       html_extract_links(html::HTML) AS links
FROM sections;
-- Discover: SELECT DISTINCT fragment FROM agents.ext_doc_sections WHERE url = '...';
-- Consume:  SELECT fragment, markdown FROM agents.ext_doc_sections
--           WHERE url = 'https://duck-hunt.readthedocs.io/en/latest/examples/'
--             AND fragment IN ('#aggregation', '#dynamic-regexp-parser');
-- These views parse cached HTML; selecting a section performs no network fetch.
-- Heading intervals are not a universal DOM selector: ID-bearing non-headings are excluded,
-- and unusually nested headings can end at a container boundary. Inspect such sites first.
-- Keep the existing catalog unchanged; consumers join on extension_name.
CREATE OR REPLACE VIEW agents.ext_catalog_documented AS
SELECT c.*, s.doc_url FROM agents.ext_catalog c LEFT JOIN agents.ext_doc_source s USING (extension_name);
SELECT representation, len(array_agg(url)) AS stored_pages, sum(length(content)) AS chars
FROM agents.ext_doc_content GROUP BY representation;

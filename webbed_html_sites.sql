-- Generic bounded HTML-site reader. Each path retains its raw body in DuckDB;
-- output is only size, first 50 characters, Webbed block count, and eight links.
-- crawler: timeout=30s, workers=1, batch_size=1, delay=0ms, follow='',
-- max_depth=1, cache=false, max_results=1. http_client and curl are one-page reads.
-- Agent choice: use http_client for one known ordinary page; use crawler when
-- discovered links, robots policy, depth, caching, and per-page receipts matter;
-- use ShellFS curl only when exact CLI behavior, proxy/TLS/cookie flags, or an
-- external reproduction matters. Keep every document in DuckDB and return only
-- bounded columns below: that projection, not the transport, reduces context tokens.
-- Robustness is scope-specific: crawler is the robust crawl engine, http_client
-- is the most composable direct DuckDB call, and curl is the compatibility escape hatch.
INSTALL crawler FROM community;
LOAD crawler;
INSTALL http_client FROM community;
LOAD http_client;
INSTALL webbed FROM community;
LOAD webbed;
LOAD shellfs;

WITH crawler_raw AS (
    -- crawl(...) returns one row per fetched URL. We keep its structured crawl
    -- receipt: url VARCHAR, status INTEGER, html.document VARCHAR, error VARCHAR.
    -- Gotcha: configure all crawl bounds deliberately; it is unnecessary overhead
    -- for a single fixed URL, but the right default for controlled link expansion.
    SELECT url, status, html.document::HTML AS document, error
    FROM crawl(
        ['https://duck-tails.readthedocs.io/en/latest/'],
        cache_ttl := 24,
        cache := false,
        follow := '',
        "extract" := []::VARCHAR[],
        max_depth := 1,
        respect_robots := true,
        workers := 1,
        batch_size := 1,
        max_results := 1,
        user_agent := 'InFrame webbed HTML sites reader/1.0',
        timeout := 30,
        state_table := '',
        delay := 0
    )
),
http_client_raw AS (
    -- http_get(...) returns one response STRUCT. Fields used here are
    -- response.status INTEGER and response.body JSON text; extract its JSON
    -- string payload before casting the HTML document.
    -- Default for a known one-page fetch: scalar, composable in a CTE, and no
    -- crawl state. Gotcha: body is JSON-encoded here, so direct ::HTML is wrong.
    SELECT response.status::VARCHAR AS status,
           json_extract_string(response.body, '$')::HTML AS document
    FROM (SELECT http_get('https://duck-tails.readthedocs.io/en/latest/') AS response)
),
curl_raw AS (
    -- ShellFS exposes the curl stdout as the declared CSV row
    -- {body_base64 VARCHAR}; base64 keeps an arbitrary HTML body in one field.
    -- Escape hatch for native curl flags. Gotchas: base64 expands stored bytes,
    -- and status/headers/errors are not structured unless curl emits them too.
    SELECT decode(from_base64(body_base64))::HTML AS document
    FROM read_csv(
        $cmd$curl -sS -L 'https://duck-tails.readthedocs.io/en/latest/' | base64 | tr -d '\n' |$cmd$,
        header := false,
        columns := {'body_base64': 'VARCHAR'}
    )
),
documents AS (
    -- Normalize every transport to one relation:
    -- {source, url, status, document HTML, error}. Curl has body-only output,
    -- so status/error are NULL unless the curl command is extended to emit them.
    SELECT 'crawler' AS source, url, status::VARCHAR AS status, document, error
    FROM crawler_raw
    UNION ALL
    SELECT 'http_client', 'https://duck-tails.readthedocs.io/en/latest/', status, document, NULL::VARCHAR
    FROM http_client_raw
    UNION ALL
    SELECT 'shellfs_curl', 'https://duck-tails.readthedocs.io/en/latest/', NULL::VARCHAR, document, NULL::VARCHAR
    FROM curl_raw
),
page_summary AS (
    -- Webbed-derived facts: extracted_links is LIST<STRUCT(text, href, title, line_number)>.
    SELECT *, len(document)::BIGINT AS raw_chars,
           left(document::VARCHAR, 50) AS preview,
           len(html_to_duck_blocks(document))::BIGINT AS block_count,
           html_extract_links(document) AS extracted_links
    FROM documents
),
responses AS (
    SELECT source, 'response' AS row_kind, url, status, raw_chars, preview, block_count,
           NULL::VARCHAR AS link_text, NULL::VARCHAR AS href, error
    FROM page_summary
),
links AS (
    -- UNNEST changes the link list into one row per link STRUCT.
    SELECT raw.source, 'link' AS row_kind, raw.url, raw.status,
           NULL::BIGINT AS raw_chars, NULL::VARCHAR AS preview, NULL::BIGINT AS block_count,
           left(link.text, 50) AS link_text, link.href, raw.error,
           row_number() OVER (PARTITION BY raw.source ORDER BY link.href) AS source_link_number
    FROM page_summary AS raw
    CROSS JOIN UNNEST(raw.extracted_links) AS links(link)
)
SELECT * FROM responses
UNION ALL
SELECT source, row_kind, url, status, raw_chars, preview, block_count, link_text, href, error
FROM links
WHERE source_link_number <= 8
ORDER BY source, row_kind, href;

-- Bounded two-path proof for the webbed extension page. Full documents remain in DuckDB;
-- this final SELECT returns only 50-character previews, block metadata, parsed SQL summaries,
-- and eight links per path.
INSTALL crawler FROM community;
LOAD crawler;
INSTALL http_client FROM community;
LOAD http_client;
INSTALL webbed FROM community;
LOAD webbed;
INSTALL parser_tools FROM community;
LOAD parser_tools;

WITH crawler_raw AS (
    SELECT
        'crawler' AS source,
        status::VARCHAR AS status,
        html.document::HTML AS document,
        error
    FROM crawl(
        ['https://duckdb.org/community_extensions/extensions/webbed'],
        cache_ttl := 24,
        cache := false,
        follow := '',
        "extract" := []::VARCHAR[],
        max_depth := 1,
        respect_robots := true,
        workers := 1,
        batch_size := 1,
        max_results := 1,
        user_agent := 'InFrame webbed docs reader/1.0',
        timeout := 30,
        state_table := '',
        delay := 0
    )
),
http_client_raw AS (
    SELECT
        'http_client' AS source,
        response.status::VARCHAR AS status,
        response.body::HTML AS document,
        NULL::VARCHAR AS error
    FROM (
        SELECT http_get('https://duckdb.org/community_extensions/extensions/webbed') AS response
    )
),
sources AS (
    SELECT * FROM crawler_raw
    UNION ALL
    SELECT * FROM http_client_raw
),
responses AS (
    SELECT
        source,
        'response' AS row_kind,
        status,
        len(document)::BIGINT AS raw_chars,
        NULL::VARCHAR AS element_type,
        left(document::VARCHAR, 50) AS preview,
        NULL::VARCHAR AS href,
        NULL::BOOLEAN AS parsable_sql,
        NULL::VARCHAR AS parsed_functions,
        error
    FROM sources
),
blocks AS (
    SELECT
        source,
        status,
        error,
        block
    FROM sources
    CROSS JOIN UNNEST(html_to_duck_blocks(document)) AS blocks(block)
),
ranked_code_blocks AS (
    SELECT
        source,
        'code_block' AS row_kind,
        status,
        NULL::BIGINT AS raw_chars,
        block.element_type AS element_type,
        left(block.content, 50) AS preview,
        NULL::VARCHAR AS href,
        is_parsable(block.content) AS parsable_sql,
        parse_function_names(block.content)::VARCHAR AS parsed_functions,
        error,
        row_number() OVER (PARTITION BY source ORDER BY block.element_order) AS source_block_number
    FROM blocks
    WHERE block.element_type = 'code'
),
ranked_links AS (
    SELECT
        source,
        'link' AS row_kind,
        status,
        NULL::BIGINT AS raw_chars,
        NULL::VARCHAR AS element_type,
        left(link.text, 50) AS preview,
        link.href,
        NULL::BOOLEAN AS parsable_sql,
        NULL::VARCHAR AS parsed_functions,
        error,
        row_number() OVER (PARTITION BY source ORDER BY link.href) AS source_link_number
    FROM sources
    CROSS JOIN UNNEST(html_extract_links(document)) AS links(link)
)
SELECT * FROM responses
UNION ALL
SELECT source, row_kind, status, raw_chars, element_type, preview, href, parsable_sql, parsed_functions, error
FROM ranked_code_blocks
WHERE source_block_number <= 8
UNION ALL
SELECT source, row_kind, status, raw_chars, element_type, preview, href, parsable_sql, parsed_functions, error
FROM ranked_links
WHERE source_link_number <= 8
ORDER BY source, row_kind, href;

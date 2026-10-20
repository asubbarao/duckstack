-- Macros Alok approved, read by setup.sql and ~/.duckdbrc.
-- quote_literal: a value as a single-quoted SQL literal, for SQL that SQL writes.
CREATE OR REPLACE MACRO quote_literal(s) AS concat($q$'$q$, replace(s, $q$'$q$, $q$''$q$), $q$'$q$);
-- selfdispatch: post one SQL statement to dev's /sql and return the receipt (status, body, error). Callers collect
-- receipts with array_agg(selfdispatch(sql)) and UNNEST them; a failed statement stays a receipt, no rows post nothing.
-- The post always goes to dev itself; whatever varies by row (a URL, a command, a file) goes inside the statement.
-- A failed statement comes back as a non-200 with the DuckDB error in the body's detail; error carries it, so
-- failures show in receipt.error. The one-element list makes the lambda post once (a macro argument used twice posts twice).
CREATE OR REPLACE MACRO selfdispatch(sql) AS
    list_transform([quackapi_post('http://127.0.0.1:9495/sql', json_object('sql', sql)::VARCHAR)],
        p -> {'status': p.status, 'body': p.body,
              'error': coalesce(p.error, CASE WHEN p.status IS DISTINCT FROM 200
                                              THEN coalesce(try_cast(p.body AS JSON) ->> 'detail', p.body::VARCHAR) END)})[1];

-- web_page: one full HTTP receipt and whole-document webbed columns; callers choose what to project.
CREATE OR REPLACE MACRO web_page(page_url) AS TABLE
WITH fetched AS (
    SELECT page_url AS requested_url, content AS full_response
    FROM read_text(tera_render($curl$curl -sSL --compressed --max-time 30 --max-redirs 8 --max-filesize 16777216 --proto '=http,https' --proto-redir '=http,https' --config - --write-out '\n__DUCK_WEB_METADATA__{"transfer":%{json},"headers":%{header_json}}' <<'CURL_REQUEST'
url = {{ url | json_encode() }}
CURL_REQUEST
true |$curl$, {url: page_url}::JSON, autoescape := false))
), receipt AS (
    SELECT *, list_last(string_split(full_response, E'\n__DUCK_WEB_METADATA__')) AS metadata_text,
           metadata_text::JSON AS metadata,
           left(full_response, length(full_response) - length(metadata_text) - length(E'\n__DUCK_WEB_METADATA__')) AS body
    FROM fetched
), typed AS (
    SELECT *, coalesce(nullif(metadata ->> '$.transfer.url_effective', ''), requested_url) AS url,
           url_parse(url) AS url_parts, metadata -> '$.headers' AS headers,
           metadata ->> '$.transfer.content_type' AS content_type,
           nullif(metadata ->> '$.transfer.errormsg', '') AS error,
           CASE WHEN (metadata ->> '$.transfer.exitcode')::INTEGER = 0
                THEN (metadata ->> '$.transfer.response_code')::INTEGER ELSE 0 END AS status,
           '' AS reason, CASE WHEN contains(lower(content_type), 'html') THEN body::HTML END AS html,
           json_object('status', status, 'body', body, 'headers', headers, 'error', error,
                       'url', url, 'requested_url', requested_url, 'metadata', metadata) AS response
    FROM receipt
)
SELECT *, coalesce(html_to_duck_blocks(html), []) AS duckblocks,
       coalesce(html_extract_links(html), []) AS raw_links,
       list_transform(raw_links, link -> struct_insert(link, url := url_resolve(url, link.href))) AS links,
       html_extract_images(html) AS images, html_extract_tables_json(html) AS tables,
       parse_html(html::VARCHAR) AS dom, coalesce(xml_extract_attributes(dom, '//*'), []) AS attributes,
       xml_to_json(dom)::JSON AS document,
       list_transform(list_filter(attributes, a -> a.attribute_name IN ('href', 'src', 'action', 'poster', 'data-src')),
                      a -> {element: a.element_name, url: url_resolve(url, a.attribute_value)}) AS resolved,
       list_distinct(list_concat(extract_urls(body), list_transform(resolved, r -> r.url))) AS urls,
       list_transform(list_filter(resolved, r -> r.element = 'iframe'), r -> r.url) AS frames
FROM typed;

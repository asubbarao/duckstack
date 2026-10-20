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

-- web_page: one structured curl receipt and whole-document webbed columns; callers choose what to project.
CREATE OR REPLACE MACRO web_page(page_url) AS TABLE
WITH fetched AS (
    SELECT page_url AS requested_url, 16777216 AS max_body_bytes, f::JSON AS full_response, f.body_base64::VARCHAR AS body_base64,
           f.headers::JSON AS headers, f.transfer AS transfer
    FROM read_json(tera_render($curl$bash <<'WEB_REQUEST'
work=$(mktemp -d)
trap 'rm -f "$work/body"; rmdir "$work"' EXIT
mkfifo "$work/body"
{
  exec 4<> "$work/body"
  { { head -c 16777217; cat > /dev/null; } < "$work/body" | base64 | tr -d '\n' | jq -Rs '{body_base64: .}' >&3; } 4>&- &
  body_pid=$!
  metadata=$(curl -sL --compressed --max-time 30 --max-redirs 8 --max-filesize 16777216 --proto '=http,https' --proto-redir '=http,https' --output "$work/body" --config - --write-out '{"transfer":%{json},"headers":%{header_json}}\n' <<'CURL_REQUEST'
url = {{ url | json_encode() }}
CURL_REQUEST
  )
  exec 4>&-
  wait "$body_pid"
  printf '%s\n' "$metadata"
} 3>&1 | jq -s add
WEB_REQUEST
|$curl$, {url: CASE WHEN starts_with(page_url, 'https://') THEN page_url WHEN starts_with(page_url, 'http://') THEN page_url ELSE '' END}::JSON, autoescape := false), maximum_object_size := 67108864) AS f
), bytes AS (
    SELECT *, from_base64(body_base64) AS raw_body FROM fetched
), typed AS (
    SELECT * EXCLUDE(transfer), transfer::JSON AS metadata,
           CASE WHEN octet_length(raw_body) <= max_body_bytes THEN try(decode(raw_body)) END AS body,
           coalesce(nullif(transfer.url_effective::VARCHAR, ''), requested_url) AS url, url_parse(url) AS url_parts,
           transfer.content_type::VARCHAR AS content_type, coalesce(nullif(transfer.errormsg::VARCHAR, ''), CASE WHEN octet_length(raw_body) > max_body_bytes THEN 'Decoded body exceeds 16 MiB; raw_body retains a truncated prefix'
                WHEN body IS NULL THEN 'Body is not UTF-8; raw_body retains its bytes' END) AS error,
           CASE WHEN error IS NULL THEN transfer.response_code::INTEGER ELSE 0 END AS status,
           CASE WHEN contains(lower(content_type), 'html') THEN body::HTML END AS html,
           json_merge_patch(full_response, json_object('body', body, 'status', status, 'error', error, 'url', url, 'requested_url', requested_url)) AS response
    FROM bytes
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

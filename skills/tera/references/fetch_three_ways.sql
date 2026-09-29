-- fetch_three_ways.sql: one page, one context, three templates (fetch_crawler / fetch_shellfs / fetch_http_client.tera).
-- The context is data: scalars are flags and := parameters, lists are loops. Each template renders one statement;
-- /sql runs it (self-dispatch); the receipts are compared after ::HTML. Run it on the dev server.
-- A failed dispatch stays a row: its receipt body lands in `error`. The crawler template renders a literal-url crawl().
-- Verified 2026-09-29: three 200 rows, same title and 31 links; crawler body 274,096 chars, curl/http_client 274,457.
--
-- tera_render(template VARCHAR [, context JSON]) -> VARCHAR   (autoescapes: ' becomes &#x27;)          tera
-- html_unescape(VARCHAR) -> VARCHAR; html_extract_text(HTML, selector); html_extract_links(HTML)       webbed
-- http_post(url VARCHAR, headers MAP, body JSON [, params MAP]) -> JSON {status, reason, body}          http_client
-- read_text(glob) -> filename, content, size, last_modified
WITH templates AS (
    SELECT parse_filename(filename) AS template, content,
        json_object('url', 'https://duckdb.org/community_extensions/extensions/duckpgq', 'user_agent', 'duckstack-tera/1.0',
            'timeout', 20, 'max_bytes', 5000000,
            'headers', [{'name': 'Accept', 'value': 'text/html'}, {'name': 'Accept-Language', 'value': 'en'}],
            'params', [{'name': 'ref', 'value': 'duckstack'}, {'name': 'via', 'value': 'tera'}]) AS ctx
    FROM read_text('/Users/aloksubbarao/duckdb-skills/skills/tera/references/fetch_*.tera')
),
rendered AS (
    SELECT template, ctx, html_unescape(tera_render(content, ctx)) AS statement FROM templates
),
fired AS (
    SELECT *, http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'},
        json_object('sql', statement))::STRUCT(status INTEGER, reason VARCHAR, body VARCHAR) AS receipt
    FROM rendered
),
landed AS (
    SELECT * EXCLUDE (receipt, statement, ctx), receipt.status AS dispatch_status,
        unnest(CASE WHEN receipt.status = 200
            THEN from_json(receipt.body, '[{"method":"VARCHAR","status":"INTEGER","body":"VARCHAR","error":"VARCHAR"}]')
            ELSE [{'method': NULL, 'status': NULL, 'body': NULL, 'error': receipt.body}] END, recursive := true)
    FROM fired
),
pages AS (
    SELECT * EXCLUDE (body), body::HTML AS page, length(body) AS body_chars, md5(body) AS body_md5 FROM landed
)
SELECT * EXCLUDE (page), html_extract_text(page, '//title') AS title, len(html_extract_links(page)) AS links
FROM pages
ORDER BY template;

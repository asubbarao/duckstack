-- Extension docs: lake.agents.ext_fetch keeps every fetch (url, fetched_at, response {status, body}); agents.ext_docs is
-- each fetch with its page as markdown (a community page carries the extension's whole function reference). Daily, the
-- community list and every extension page it links are fetched again: one curl per url, four /sql bodies run in order.
-- (url, fetched_at) is the key: a rerun of the same batch inserts nothing.
CREATE SCHEMA IF NOT EXISTS agents;
SELECT cron($$
WITH urls AS (
    SELECT 'https://duckdb.org/community_extensions/list_of_extensions' AS url
    UNION
    SELECT url_resolve(f.url, l.href) AS url FROM lake.agents.ext_fetch f
    CROSS JOIN UNNEST(html_extract_links(parse_html(f.response ->> 'body'))) AS u(l)
    WHERE f.url = 'https://duckdb.org/community_extensions/list_of_extensions'
      AND urlpattern_test('https://duckdb.org/community_extensions/extensions/:name.html', url_resolve(f.url, l.href))
), batches AS (
    SELECT list(url ORDER BY url) AS urls, quote_literal(now()) AS fetched_at FROM urls GROUP BY hash(url) % 4
), statements AS (
    SELECT tera_render($t$
{% for url in urls %}
MERGE INTO lake.agents.ext_fetch AS target
USING (
    SELECT $url${{ url }}$url$ AS url, {{ fetched_at }}::TIMESTAMPTZ AS fetched_at, json_object('status', 200, 'body', content) AS response
    FROM read_text($cmd$curl -sSL --fail --max-time 30 '{{ url }}' |$cmd$)
) AS source ON target.url = source.url AND target.fetched_at = source.fetched_at
WHEN NOT MATCHED THEN INSERT BY NAME;
{% endfor %}
$t$, c::JSON, autoescape := false) AS sql
    FROM batches c
), posted AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM statements
)
SELECT r.* FROM posted CROSS JOIN UNNEST(receipts) AS t(r)
$$, '0 15 3 * * *');

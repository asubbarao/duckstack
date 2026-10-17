-- One page per row: inline command template -> JSON self-posts -> array -> receipts.
-- Selected dev: 9495. Timeout 30 s per curl; two seeds, no retries/delay/link following,
-- depth 0, no cache, one page per seed. Raw pages land in lake.agents.ext_fetch.
-- A failed fetch lands no row; its SQL error remains in the dispatch receipt.
WITH due AS (
    SELECT unnest([
        'https://duckdb.org/community_extensions/extensions/tera.html',
        'https://duckdb.org/community_extensions/extensions/no_such_extension_zz'
    ]) AS url, now() AS fetched_at
), statements AS (
    SELECT url, tera_render($t$
MERGE INTO lake.agents.ext_fetch AS target
USING (
    SELECT $url${{ url }}$url$ AS url, '{{ fetched_at }}'::TIMESTAMPTZ AS fetched_at,
           json_object('status', 200, 'body', content) AS response
    FROM read_text($cmd$curl -sSL --fail --max-time 30 '{{ url }}' |$cmd$)
) AS source ON target.url = source.url AND target.fetched_at = source.fetched_at
WHEN NOT MATCHED THEN INSERT BY NAME
$t$, c::JSON, autoescape := false) AS sql
    FROM due c
), posted AS (
    SELECT array_agg({url: url, receipt: selfdispatch(sql)}) AS receipts
    FROM statements
)
SELECT r.url, unnest(r.receipt) FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

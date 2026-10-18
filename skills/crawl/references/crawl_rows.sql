-- One page per row: inline command template -> JSON self-posts -> array -> receipts.
-- Selected dev: 9495. Timeout 30 s per curl; workers: one post per url, sent together; batch: the
-- seed list; no delay, no retries, no link following, depth 0; cache: a url fetched in the last day
-- is skipped; one page per seed. Raw pages land in lake.agents.ext_fetch (appends, never MERGE).
-- A failed fetch lands no row; its SQL error remains in the dispatch receipt.
WITH seeds AS (
    SELECT unnest([
        'https://duckdb.org/community_extensions/extensions/tera.html',
        'https://duckdb.org/community_extensions/extensions/no_such_extension_zz'
    ]) AS url, now() AS fetched_at
), due AS (
    SELECT url, fetched_at FROM seeds
    ANTI JOIN (FROM lake.agents.ext_fetch WHERE fetched_at > now() - INTERVAL 1 DAY) AS recent USING (url)
), rendered AS (
    SELECT tera_render($tera$
INSERT INTO lake.agents.ext_fetch BY NAME
SELECT '{{ url }}' AS url, '{{ fetched_at }}'::TIMESTAMPTZ AS fetched_at,
       json_object('status', 200, 'body', content) AS response
FROM read_text($cmd$curl -sSL --fail --max-time 30 '{{ url }}' |$cmd$)
$tera$, due::JSON, autoescape := false) AS sql
    FROM due
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

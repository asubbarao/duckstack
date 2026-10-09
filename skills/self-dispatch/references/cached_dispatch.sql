-- Self-caching dispatch: the receipt table is the cache.
--
-- Each miss is posted wrapped in INSERT ... RETURNING, so the dispatched statement
-- stores its own answer and returns it in one step. The outer query anti-joins the
-- generated statements against receipts younger than the TTL and posts only the misses.
--
-- Verified on dev 2026-10-07 with the query.farm VGI geocoding example:
--   run 1: 5 input rows -> 3 distinct statements -> 3 posts -> 3 cache rows, 12 result rows
--          (the zero-match place is cached as [] and kept by the join on the key)
--   run 2: the same 12 rows, every one source = 'cache'; the cache still held 3 rows (0 posts)
--
-- Facts measured on the way:
--   * Dedupe is DISTINCT on the generated statement text (want), before the post.
--     array_agg(DISTINCT http_post(...)) dedupes receipts after every call has already run.
--   * http_post ran the 3 posts one after another: the inner now() stamps were 1.7 s and
--     0.9 s apart, and its 10 s read timeout is hardcoded (fix belongs upstream in httpclient).
--     For long or parallel posts use curl through shellfs (see SKILL.md); quackapi is serve-only.
--     One trial outran the 10 s limit (an open-meteo retry took 14 s): the client reported -1,
--     and every row still landed. Treat -1 as uncertain and check the table before re-posting.
--   * This cache is a maintained table, which the house rule "everything is a view" disfavours:
--     the receipts could instead land as files (COPY … PARTITION_BY) and the cache be a view over
--     them. Kept here as the measured, working form; convert before relying on it.
--   * quackapi has no result cache (one was removed 2026-09-02 because it was keyed only on
--     the SQL text and never expired). This table is the cache layer.
--   * Pure quack cannot be the transport: quack_query is a table function, so its SQL must be
--     a bind-time literal. A scalar quack_exec(uri, sql) would make it a drop-in for http_post.
--
-- Rules for the cache:
--   * cache reads only; never cache a statement that writes elsewhere (replaying it is unsafe)
--   * the key is md5 of the whole generated statement (schema, arguments, filters are inside it);
--     add a version or identity tag when the answer depends on data or credentials outside it
--   * post stays referenced exactly once along a linear chain, so it can never be inlined twice
--     and post twice; fresh is read twice, which is safe (one snapshot, read-only)

CREATE TABLE IF NOT EXISTS dispatch_cache AS
SELECT ''::VARCHAR AS stmt_hash, ''::VARCHAR AS statement, '[]'::JSON AS body, now() AS fetched_at
LIMIT 0;

WITH places(city) AS (
    VALUES ('Glen Allen'), ('No such place zxqv'), ('Ocean City'), ('ocean city'), ('  OCEAN CITY  ')
), keyed AS (
    SELECT city, stmt, md5(stmt) AS stmt_hash
    FROM (
        SELECT city, printf($$SELECT r.name, r.admin1, r.country FROM read_text('https://geocoding-api.open-meteo.com/v1/search?name=%s&count=3&countryCode=US') CROSS JOIN UNNEST(from_json(json_extract(content, '$.results'), '[{"name":"VARCHAR","admin1":"VARCHAR","country":"VARCHAR"}]')) AS u(r)$$, url_encode(lower(trim(city)))) AS stmt
        FROM places
    )
), want AS (
    SELECT DISTINCT stmt, stmt_hash FROM keyed
), fresh AS (
    SELECT stmt_hash, arg_max(body, fetched_at) AS body
    FROM dispatch_cache
    WHERE fetched_at > now() - INTERVAL 10 MINUTE
      AND stmt_hash IN (SELECT stmt_hash FROM want)
    GROUP BY stmt_hash
), misses AS (
    SELECT stmt, stmt_hash FROM want ANTI JOIN fresh USING (stmt_hash)
), post AS (
    SELECT array_agg(http_post(
        'http://127.0.0.1:9495/sql',
        MAP {'Content-Type': 'application/json'},
        json_object('sql', printf($$INSERT INTO dispatch_cache BY NAME SELECT '%s' AS stmt_hash, $stmt$%s$stmt$ AS statement, coalesce(to_json(list(t)), '[]'::JSON) AS body, now() AS fetched_at FROM (%s) AS t RETURNING stmt_hash, body::VARCHAR AS body$$, stmt_hash, stmt, stmt))
    )) AS receipts
    FROM misses
), dispatched AS (
    SELECT receipt ->> '$.status' AS status, e.stmt_hash, e.body::JSON AS body
    FROM post
    CROSS JOIN UNNEST(receipts) AS r(receipt)
    CROSS JOIN UNNEST(from_json(receipt ->> '$.body', '[{"stmt_hash":"VARCHAR","body":"VARCHAR"}]')) AS x(e)
), answers AS (
    SELECT stmt_hash, 'cache' AS source, '200' AS status, body FROM fresh
    UNION ALL BY NAME
    SELECT stmt_hash, 'dispatched' AS source, status, body FROM dispatched
), matches AS (
    SELECT a.stmt_hash, a.source, a.status, m.name, m.admin1, m.country
    FROM answers a
    CROSS JOIN UNNEST(CASE WHEN json_array_length(a.body) = 0 THEN [NULL] ELSE from_json(a.body, '[{"name":"VARCHAR","admin1":"VARCHAR","country":"VARCHAR"}]') END) AS u(m)
)
SELECT k.city, x.source, x.status, x.name AS matched_name, x.admin1, x.country
FROM keyed k JOIN matches x USING (stmt_hash)
ORDER BY k.city, x.admin1;

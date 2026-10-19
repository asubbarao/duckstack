-- The lake sits on top of the work: attached last, in one post, so a lake failure fails this post and dev keeps serving.
-- The catalog holds its own data path. 4318 OTLP/HTTP into the lake: otlp_serve creates lake.otel.otlp_* (logs, traces,
-- metrics_sum, _gauge, _histogram, _exp_histogram) and commits buffered rows about every 5 s; otlp_stop() commits them, a
-- kill drops them. After its commits it runs CHECKPOINT lake, and it sets the lake's GLOBAL expire_older_than /
-- delete_older_than to maintenance_retention_ms (default 15 min): every lake table's snapshots older than that are
-- expired. 30 days here.
WITH program AS (
    SELECT $lake$
FROM read_csv($cmd$mkdir -p "$HOME/.duck/lake/duckstack" && echo ready |$cmd$, header := false);
ATTACH IF NOT EXISTS 'ducklake:~/.duck/lake/duckstack/catalog.ducklake' AS lake (DATA_INLINING_ROW_LIMIT 0);
CREATE SCHEMA IF NOT EXISTS lake.otel;
CREATE SCHEMA IF NOT EXISTS lake.agents;
CREATE TABLE IF NOT EXISTS lake.agents.ext_fetch (url VARCHAR, fetched_at TIMESTAMPTZ, response JSON);
FROM otlp_serve('otlp:127.0.0.1:4318', catalog := 'lake', schema := 'otel', disable_auth := true, maintenance_retention_ms := 2592000000);
$lake$ AS sql
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM program
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

-- BM25 over agent.stream_hour (native fts index, rebuilt by agent_stream_hour_index.sql). Five session-hours,
-- each with its ids count and up to five matching condensed items (id + speaker-prefixed head/tail, <= 205 chars).
-- Never full text: fetch a row with stream_message(id). The quoted phrase is the tool's $q placeholder.
WITH scored AS (
    SELECT *, fts_agent_stream_hour.match_bm25(hour_id, 'launchctl plist wrapper server exits log') AS score,
        list_transform(list_filter(string_split(lower('launchctl plist wrapper server exits log'), ' '),
            w -> len(w) > 2), w -> stem(w, 'porter')) AS stems
    FROM agent.stream_hour
), top AS (
    SELECT * FROM scored WHERE score IS NOT NULL ORDER BY score DESC LIMIT 5
), items AS (
    SELECT *, list_transform(list_zip(ids, condensed_items), x -> {
            hits: len(list_filter(stems, w -> contains(lower(x[2]), w))), id: x[1], item: x[2]}) AS scored_items
    FROM top
)
SELECT round(score, 3) AS score, system, session_id, hour, project_path, first_ts, last_ts,
    message_count, role_counts, hour_id,
    list_reverse_sort(list_filter(scored_items, x -> x.hits > 0))[:5] AS matches
FROM items
ORDER BY score DESC
LIMIT 5;

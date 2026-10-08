-- Cosine search over agent.stream_hour_vector (same model and text as agent_stream_hour_index.sql). An exact scan:
-- at ~1.5k hour vectors it is milliseconds, so there is no HNSW index. Returns five session-hours with up to five
-- human/agent condensed items (id + head/tail); full text via stream_message(id). The quoted phrase is $q.
LOAD quackformers;
WITH scored AS (
    SELECT v.hour_id, array_cosine_similarity(v.embedding,
        embed('launchctl plist wrapper server exits log')::FLOAT[384]) AS similarity
    FROM agent.stream_hour_vector AS v
    JOIN duckdb_extensions() AS e ON e.extension_name = v.model_extension AND e.extension_version = v.model_version
    ORDER BY similarity DESC
    LIMIT 5
)
SELECT round(s.similarity, 3) AS similarity, h.system, h.session_id, h.hour, h.project_path, h.first_ts, h.last_ts,
    h.message_count, h.role_counts, h.hour_id,
    list_filter(list_transform(list_zip(h.ids, h.condensed_items), x -> {id: x[1], item: x[2]}),
        x -> split_part(x.item, ':', 1) IN ('human', 'agent'))[:5] AS dialog
FROM scored AS s
JOIN agent.stream_hour AS h USING (hour_id)
ORDER BY s.similarity DESC
LIMIT 5;

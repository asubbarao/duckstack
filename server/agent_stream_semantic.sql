-- Same model and normalized message_content as the scheduled local embedding job.
WITH asked AS (
    SELECT embed('launchctl plist wrapper server exits log')::FLOAT[384] AS embedding,
        extension_version AS model_version
    FROM duckdb_extensions() WHERE extension_name = 'quackformers'
), matches AS (
    SELECT s.system, s.session_id, s.day,
        max(array_cosine_similarity(v.embedding, q.embedding)) AS similarity
    FROM agent.stream_vector v
    JOIN agent.stream s ON s.id = v.id AND sha256(s.message_content) = v.content_hash
    CROSS JOIN asked q
    WHERE v.model_version = q.model_version
    GROUP BY ALL
    ORDER BY similarity DESC
    LIMIT 10
)
SELECT m.similarity, d.*
FROM matches m JOIN agent.stream_day d
    ON m.system IS NOT DISTINCT FROM d.system
    AND m.session_id IS NOT DISTINCT FROM d.session_id
    AND m.day IS NOT DISTINCT FROM d.day
ORDER BY m.similarity DESC;

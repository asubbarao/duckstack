-- One row per UTC session-day. Change only asked; choose richer columns in the final SELECT.
WITH asked AS (
    SELECT 'launchctl plist wrapper server exits log'::VARCHAR AS q,
        '0123456789!@#$%^&*()_+={}[]:;<>,.?~\\/|''"`-' || chr(9) || chr(10) || chr(13) AS separators
), words AS (
    SELECT unnest(string_split(translate(lower(strip_accents(q)), separators,
        repeat(' ', length(separators))), ' ')) AS word
    FROM asked
), terms AS (
    SELECT list(DISTINCT stem(word, 'porter')) AS match_arr
    FROM words ANTI JOIN agent.bm25_stopword ON word = sw
    WHERE nullif(word, '') IS NOT NULL
), stats AS (
    SELECT count(id) AS documents, avg(len) AS average_length
    FROM agent.stream_bm25_length
), frequencies AS (
    SELECT p.term, count(p.id) AS documents_with_term
    FROM agent.stream_bm25_posting p CROSS JOIN terms
    WHERE list_contains(match_arr, p.term)
    GROUP BY p.term
), scores AS (
    SELECT p.id, sum(ln(1 + (s.documents - f.documents_with_term + 0.5) / (f.documents_with_term + 0.5))
        * p.tf * 2.2 / (p.tf + 1.2 * (0.25 + 0.75 * d.len / s.average_length))) AS bm25
    FROM agent.stream_bm25_posting p JOIN frequencies f USING (term)
    JOIN agent.stream_bm25_length d USING (id) CROSS JOIN stats s
    GROUP BY p.id
), items AS (
    SELECT s.*, b.bm25,
        list_contains(list_transform(['<task-notification>', 'This session is being continued from a previous conversation',
            '# AGENTS.md instructions', '<environment_context>'], p -> starts_with(s.message_content, p)), true) AS is_harness,
        s.message_role IN ('user', 'agent', 'tool_call', 'tool_result') AND NOT is_harness AS searchable,
        {ts: s.ts, id: s.id, uuid: s.uuid, role: s.message_role, content: s.message_content, harness: is_harness} AS item
    FROM agent.stream s LEFT JOIN scores b USING (id)
), sessions AS (
    SELECT system, session_id, day, min(ts) AS first_ts, max(ts) AS last_ts,
        list(DISTINCT coalesce(nullif(cwd, ''), nullif(project_path, ''))) AS directories,
        list(DISTINCT repository) FILTER (WHERE repository IS NOT NULL) AS repositories,
        count(id) AS message_count, count(bm25) FILTER (WHERE searchable) AS bm25_matches,
        count(id) FILTER (WHERE message_role IN ('tool_call', 'tool_result')) AS tool_count,
        list(item ORDER BY bm25 DESC NULLS LAST, ts DESC NULLS LAST, id)
            FILTER (WHERE message_role NOT IN ('tool_call', 'tool_result')) AS all_messages,
        list(item ORDER BY bm25 DESC NULLS LAST, ts DESC NULLS LAST, id)
            FILTER (WHERE message_role IN ('tool_call', 'tool_result')) AS toolcalls,
        array_to_string(list(message_content ORDER BY ts, id), ' ') AS full_text,
        array_to_string(list(message_content ORDER BY ts, id) FILTER (WHERE searchable), ' ') AS search_text
    FROM items GROUP BY ALL
), features AS (
    SELECT s.*, a.q, t.match_arr,
        list_filter(all_messages, m -> m.role IN ('user', 'agent') AND NOT m.harness AND m.content IS NOT NULL) AS messages,
        list_filter(string_split(translate(lower(strip_accents(search_text)), a.separators,
            repeat(' ', length(a.separators))), ' '), w -> nullif(w, '') IS NOT NULL) AS words,
        list_distinct(list_transform(words, w -> stem(w, 'porter'))) AS tokens,
        ngrams(words, 2) AS bigrams, list_intersect(t.match_arr, tokens) AS matched_terms,
        list_sort(messages[:10]) AS selected_messages,
        list_transform(selected_messages, m -> [m.role, left(m.content, 75), m.ts::VARCHAR, coalesce(nullif(m.uuid, ''), m.id)]) AS message_previews
    FROM sessions s CROSS JOIN asked a CROSS JOIN terms t
)
SELECT system AS agent_type, session_id, day, directories, repositories, last_ts,
    matched_terms, message_count, tool_count, message_previews[:10] AS messages
FROM features
WHERE CASE WHEN bm25_matches > 0 THEN true
           WHEN match_arr IS NULL THEN true
           WHEN len(matched_terms) >= greatest(1, ceil(len(match_arr) / 2.0)) THEN true
           ELSE false END
ORDER BY len(matched_terms) DESC NULLS LAST, last_ts DESC NULLS LAST, system, session_id, day
LIMIT 10;

-- Builds agent.user_text and checks it, as one self-dispatch molecule. Markers only extract words from
-- known wrappers. The human/harness decision is length-tiered from the corpus p95 and match_array.
-- The query writes the CREATE VIEW, appends fail-closed checks, and posts the whole body to dev /sql.
--
-- agent.user_text: one row per user-role row of agent.stream, the wrapper it arrived in (user_kind), who
-- really wrote it (speaker), the typed words with the harness text removed (user_text), pasted text apart
-- (paste_text), and extract_status: 'ok', 'no_words', or 'unresolved: <reason>' for rows a branch's rule
-- did not handle. Readers take extract_status = 'ok'; the rest stay one WHERE away.
WITH markers AS (
    -- prefix identifies the wrapper; the person's words sit after `open` and before `close`.
    SELECT '<command-name>' AS prefix, 'slash_command' AS marker_kind, NULL AS speaker,
        '<command-args>' AS open, '</command-args>' AS close
    UNION ALL SELECT '<command-message>', 'slash_command', NULL, '<command-args>', '</command-args>'
    UNION ALL SELECT '<bash-input>', 'bang_shell', NULL, '<bash-input>', '</bash-input>'
    UNION ALL SELECT '<user_shell_command>', 'bang_shell', NULL, '<command>', '</command>'
    UNION ALL SELECT '<!-- reply', 'quoted_reply', NULL, '-->', NULL
    UNION ALL SELECT '<!-- attach:', 'quoted_reply', NULL, '-->', NULL
    UNION ALL SELECT '<realtime_delegation>', 'voice', NULL, '<input>', '</input>'
    UNION ALL SELECT '<system-reminder>', 'reminder_prefixed', NULL, '</system-reminder>', NULL
    UNION ALL SELECT '[Image #', 'image_prefixed', NULL, ']', NULL
    UNION ALL SELECT '[Image:', 'image_prefixed', NULL, ']', NULL
    UNION ALL SELECT 'Base directory for this skill', 'skill_body', NULL, 'ARGUMENTS: ', NULL
    -- Wrappers with no words of the person's.
    UNION ALL SELECT '<bash-stdout>', 'bang_output', 'tool', NULL, NULL
    UNION ALL SELECT '<local-command-stdout>', 'local_command_output', 'tool', NULL, NULL
    UNION ALL SELECT '<recommended_plugins>', 'recommended_plugins', NULL, NULL, NULL
    UNION ALL SELECT '[Request interrupted', 'interrupt', NULL, NULL, NULL
    UNION ALL SELECT '# AGENTS.md instructions', 'agents_md_preamble', NULL, NULL, NULL
    UNION ALL SELECT 'The following is the Codex agent history', 'approval_review', NULL, NULL, NULL
    UNION ALL SELECT 'This session is being continued from a previous conversation', 'compaction_summary', NULL, NULL, NULL
    -- Written by an agent, delivered to its parent as a user record.
    UNION ALL SELECT 'Another Claude session', 'subagent_report', 'agent', NULL, NULL
    UNION ALL SELECT '<task-notification>', 'task_notification', 'agent', NULL, NULL
    UNION ALL SELECT '[SYSTEM NOTIFICATION', 'harness_notice', NULL, NULL, NULL
    UNION ALL SELECT '[handback-send-enforce]', 'harness_notice', NULL, NULL, NULL
    UNION ALL SELECT '[Your previous response', 'harness_notice', NULL, NULL, NULL
    UNION ALL SELECT '[Cross-session', 'harness_notice', NULL, NULL, NULL
    UNION ALL SELECT '[external', 'harness_notice', NULL, NULL, NULL
    UNION ALL SELECT '[external_agent_tool_result]', 'harness_notice', NULL, NULL, NULL
    UNION ALL SELECT '[Usage limit reached', 'harness_notice', NULL, NULL, NULL
), marker_rows AS (
    -- Each marker as a literal SELECT row; NULL stays NULL and quotes are doubled.
    SELECT 'SELECT ' || array_to_string(list_transform([prefix, marker_kind, speaker, open, close],
        v -> CASE WHEN v IS NULL THEN 'NULL'
                  ELSE chr(39) || replace(v, chr(39), chr(39) || chr(39)) || chr(39) END), ', ') AS row_sql
    FROM markers
), view_sql AS (
    SELECT replace($view$CREATE OR REPLACE VIEW agent.user_text AS
WITH markers AS (
    SELECT * FROM (@MARKERS@) AS m(prefix, marker_kind, speaker, open, close)
), keyed AS (
    -- Marker lookup is only for wrapper extraction, never the fallback human/harness decision.
    SELECT *, CASE WHEN starts_with(prefix, '<') THEN ltrim(string_split(string_split(prefix, '>')[1], ' ')[1], '<')
                   ELSE string_split(prefix, ' ')[1] END AS lead
    FROM markers
), src AS (
    SELECT id, system, session_id, parent_session_id, project_path, ts, day, file_name, line_number,
        message_content AS c, content_length, ltrim(c) AS c_start, left(c_start, 100) AS head,
        approx_quantile(content_length, 0.95) OVER () AS p95,
        ['<command-name>', '<command-message>', '<bash-input>', '<user_shell_command>', '<!--',
         '<realtime_delegation>', '<system-reminder>', '[Image', '<bash-stdout>',
         '<local-command-stdout>', '[Request', '<task-notification>', '[SYSTEM',
         '[handback-send-enforce]', '[Your', '[Cross-session', '[external',
         '[external_agent_tool_result]', '[Usage', '<pasted_content', '<recommended_plugins>',
         '</environment_context>', '</INSTRUCTIONS>', '</task-notification>',
         '</system-reminder>', '</pasted_content>'] AS match_array,
        CASE WHEN starts_with(head, '<') THEN ltrim(string_split(string_split(head, '>')[1], ' ')[1], '<')
             -- translate turns tabs and line breaks into spaces, so a word ends at any whitespace
             ELSE string_split(translate(head, chr(9) || chr(10) || chr(13), '   '), ' ')[1] END AS lead
    FROM agent.stream
    WHERE message_role = 'user'
), long_rows AS (
    SELECT id, [left(c_start, 100), right(c_start, 100)] AS long_ends,
        list_transform(long_ends, endpoint -> len(array_intersect(
            string_split(trim(replace(replace(
                translate(endpoint, chr(9) || chr(10) || chr(13), '   '), '<', ' <'), '>', '> ')), ' '),
            match_array)) = 0) AS long_end_is_human
    FROM src
    WHERE c IS NOT NULL AND content_length > p95
), tiered AS (
    SELECT s.*, l.long_ends, l.long_end_is_human,
        CASE WHEN c IS NULL THEN false
             WHEN content_length <= 50 THEN len(array_intersect(
                 string_split(trim(replace(replace(
                     translate(left(c, 50), chr(9) || chr(10) || chr(13), '   '), '<', ' <'), '>', '> ')), ' '),
                 match_array)) = 0
             WHEN content_length <= p95 THEN true
             ELSE list_contains(long_end_is_human, true) END AS is_human
    FROM src AS s
    LEFT JOIN long_rows AS l USING (id)
), kinded AS (
    SELECT s.*, k.prefix, k.marker_kind, k.open, k.close,
        k.speaker AS marker_speaker,
        string_split(c_start, k.open) AS by_open,
        CASE WHEN k.marker_kind IS NULL THEN c
             WHEN close IS NOT NULL THEN string_split(by_open[2], close)[1]
             WHEN strpos(c_start, open) > 0 THEN substr(c_start, strpos(c_start, open) + length(open)) END
             AS wrapper_stripped,
        CASE WHEN c IS NULL THEN 'tool_result_envelope'  -- reader drops the tool_result block today
             -- These wrappers are found inside the text, not at its start, so they are decided first.
             WHEN contains(left(c, 400), 'This session is being continued from a previous conversation') THEN 'compaction_summary'
             WHEN contains(c, '<pasted_content') THEN 'paste'
             WHEN k.marker_kind IS NOT NULL THEN k.marker_kind
             WHEN contains(left(c, 400), '<INSTRUCTIONS>') THEN 'agents_md_preamble'
             WHEN starts_with(c_start, '# ') AND contains(left(c_start, 300), ' Skill') THEN 'skill_body'
             WHEN is_human THEN 'typed'
             ELSE 'harness_text' END AS user_kind,
        string_split(wrapper_stripped, '<pasted_content') AS by_paste_open,
        -- '<pasted_content id="x">body</pasted_content id="x">after': body and after follow the first '>'
        list_transform(by_paste_open[2:], p -> string_split(p, '</pasted_content')) AS paste_parts,
        list_transform(paste_parts, p -> substr(p[1], strpos(p[1], '>') + 1)) AS paste_bodies,
        list_transform(paste_parts, p -> substr(p[2], strpos(p[2], '>') + 1)) AS paste_tails,
        CASE user_kind
            WHEN 'typed' THEN c
            WHEN 'paste' THEN by_paste_open[1] || ' ' || array_to_string(paste_tails, ' ')
            WHEN 'image_prefixed' THEN CASE WHEN list_contains(list_transform(
                    ['[Image #', '[Image:'], p -> starts_with(ltrim(wrapper_stripped), p)), true)
                THEN substr(wrapper_stripped, strpos(wrapper_stripped, ']') + 1)
                ELSE wrapper_stripped END
            WHEN 'harness_text' THEN NULL
            ELSE wrapper_stripped
        END AS raw_text,
        -- Blank means only spaces, tabs and line breaks; the text itself is kept as typed.
        CASE WHEN trim(translate(raw_text, chr(9) || chr(10) || chr(13), '')) <> '' THEN raw_text END AS words
    FROM tiered AS s
    LEFT JOIN keyed AS k ON s.lead = k.lead AND starts_with(s.c_start, k.prefix)
)
SELECT * EXCLUDE (marker_speaker, words),
    CASE WHEN marker_speaker = 'agent' THEN NULL ELSE words END AS user_text,
    CASE WHEN marker_speaker = 'agent' THEN c END AS agent_text,
    CASE WHEN user_kind = 'paste' THEN array_to_string(paste_bodies, chr(10) || '---' || chr(10)) END AS paste_text,
    CASE WHEN marker_speaker IS NOT NULL THEN marker_speaker
         WHEN user_kind = 'tool_result_envelope' THEN 'tool'
         WHEN words IS NOT NULL THEN 'human'
         WHEN paste_text IS NOT NULL THEN 'human'
         ELSE 'harness' END AS speaker,
    CASE WHEN user_kind = 'paste'
             AND len(string_split(c, '<pasted_content')) <> len(string_split(c, '</pasted_content'))
             THEN 'unresolved: paste tags unbalanced'
         WHEN marker_kind = user_kind AND len(by_open) > 2 AND user_kind <> 'image_prefixed'
             THEN 'unresolved: opening tag repeated'
         WHEN marker_kind = user_kind AND close IS NOT NULL AND len(by_open) = 1
             THEN 'unresolved: opening tag missing'
         WHEN words IS NOT NULL THEN 'ok'
         WHEN paste_text IS NOT NULL THEN 'ok'
         WHEN agent_text IS NOT NULL THEN 'ok'
         ELSE 'no_words' END AS extract_status
FROM kinded;
$view$, '@MARKERS@', string_agg(row_sql, chr(10) || '    UNION ALL ')) AS statement
    FROM marker_rows
), program AS (
    -- The checks run after the view in the same body, so they read the view just created.
    SELECT statement || chr(10) || $checks$
WITH u AS (FROM agent.user_text),
check_rows AS (
    SELECT 'paste: open and close tags balance' AS rule,
        len(string_split(c, '<pasted_content')) = len(string_split(c, '</pasted_content')) AS ok, id
    FROM u WHERE user_kind = 'paste'
    UNION ALL
    SELECT user_kind || ': opening tag at most once', len(by_open) IN (1, 2), id
    FROM u WHERE marker_kind = user_kind AND open IS NOT NULL AND user_kind <> 'image_prefixed'
    UNION ALL
    SELECT 'bang_shell: always has words', user_text IS NOT NULL, id
    FROM u WHERE user_kind = 'bang_shell'
    UNION ALL
    -- Extracted words that still start with any match_array entry mean a wrapper was missed.
    SELECT 'user_text does not start with a wrapper', NOT list_contains(
            list_transform(match_array, p -> starts_with(ltrim(user_text), p)), true), id
    FROM u WHERE user_text IS NOT NULL
    UNION ALL
    SELECT 'agent-written: agent text, never user text', agent_text IS NOT NULL AND user_text IS NULL, id
    FROM u WHERE speaker = 'agent'
    UNION ALL
    SELECT 'tool_result_envelope: no content at all', c IS NULL, id
    FROM u WHERE user_kind = 'tool_result_envelope'
    UNION ALL
    SELECT 'unmarked nonhuman rows yield no user text', user_text IS NULL, id
    FROM u WHERE marker_kind IS NULL AND NOT is_human
    UNION ALL
    SELECT 'long rows use both 100-character endpoint decisions',
        len(long_ends) = 2 AND len(long_end_is_human) = 2
            AND is_human = list_contains(long_end_is_human, true), id
    FROM u WHERE content_length > p95
    UNION ALL
    SELECT 'one view row per source id',
        len(array_agg(id)) = len(array_agg(DISTINCT id)), 'all'
    FROM u
), checks AS (
    SELECT rule, NOT list_contains(array_agg(ok IS NOT TRUE), true) AS ok, len(array_agg(id)) AS n
    FROM check_rows GROUP BY rule
), asserted AS (
    SELECT rule, ok, n,
        CASE WHEN list_contains(array_agg(ok) OVER (), false)
             THEN error('agent.user_text checks failed')
             ELSE true END AS all_ok
    FROM checks
)
-- all_ok is selected so any false check aborts the operation instead of returning a false row.
SELECT rule, CASE WHEN all_ok THEN ok END AS ok, n
FROM asserted ORDER BY rule LIMIT 100$checks$ AS body
    FROM view_sql
), dispatched AS (
    SELECT array_agg(http_post('http://localhost:9495/sql', MAP {'Content-Type': 'application/json'},
        {'sql': body}::JSON)) AS responses
    FROM program
)
SELECT r.status, r.body
FROM dispatched CROSS JOIN UNNEST(responses) AS u(r);

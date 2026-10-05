-- Build and check agent.user_text through dev's same-service JSON self-dispatch route.
WITH program AS (
SELECT $sql$CREATE OR REPLACE VIEW agent.user_text AS
WITH marker_map(prefix, marker_kind, marker_speaker, open, close) AS (VALUES
 ('<command-name>','slash_command',NULL,'<command-args>','</command-args>'), ('<command-message>','slash_command',NULL,'<command-args>','</command-args>'),
 ('<bash-input>','bang_shell',NULL,'<bash-input>','</bash-input>'), ('<user_shell_command>','bang_shell',NULL,'<command>','</command>'),
 ('<!-- reply','quoted_reply',NULL,'-->',NULL), ('<!-- attach:','quoted_reply',NULL,'-->',NULL), ('<realtime_delegation>','voice',NULL,'<input>','</input>'),
 ('<system-reminder>','reminder_prefixed',NULL,'</system-reminder>',NULL), ('[Image #','image_prefixed',NULL,']',NULL), ('[Image:','image_prefixed',NULL,']',NULL),
 ('Base directory for this skill','skill_body','harness','ARGUMENTS: ',NULL), ('<bash-stdout>','bang_output','tool',NULL,NULL),
 ('<local-command-stdout>','local_command_output','tool',NULL,NULL), ('<recommended_plugins>','recommended_plugins',NULL,NULL,NULL),
 ('[Request interrupted','interrupt',NULL,NULL,NULL), ('# AGENTS.md instructions','agents_md_preamble',NULL,NULL,NULL),
 ('The following is the Codex agent history','approval_review',NULL,NULL,NULL),
 ('This session is being continued from a previous conversation','compaction_summary','harness',NULL,NULL),
 ('Another Claude session','subagent_report','agent',NULL,NULL), ('<task-notification>','task_notification','agent',NULL,NULL),
 ('[SYSTEM NOTIFICATION','harness_notice',NULL,NULL,NULL), ('[handback-send-enforce]','harness_notice',NULL,NULL,NULL),
 ('[Your previous response','harness_notice',NULL,NULL,NULL), ('[Cross-session','harness_notice',NULL,NULL,NULL),
 ('[external','harness_notice',NULL,NULL,NULL), ('[external_agent_tool_result]','harness_notice',NULL,NULL,NULL),
 ('[Usage limit reached','harness_notice',NULL,NULL,NULL), ('# Chrome tabs:','harness_notice',NULL,NULL,NULL), ('<heartbeat>','harness_notice',NULL,NULL,NULL),
 ('Your response above was cut off','harness_notice',NULL,NULL,NULL), ('The app was quit while you were working','harness_notice',NULL,NULL,NULL),
 ('The coordinator sent a message while you were working','harness_notice',NULL,NULL,NULL), ('# Files mentioned by the user:','file_list',NULL,'## My request:',NULL)
), launch_map(launch_key, launch_kind) AS (VALUES ('claude|true','caller_brief'), ('codex|false|exec|codex_exec','caller_brief'), ('codex|true|subagent|codex_exec','caller_brief')
), wrapper_map(map_key, token) AS (VALUES
 ('all','<command-name>'),('all','<command-message>'),('all','<bash-input>'),('all','<user_shell_command>'),('all','<!--'),
 ('all','<realtime_delegation>'),('all','<system-reminder>'),('all','[Image'),('all','<bash-stdout>'),('all','<local-command-stdout>'),
 ('all','[Request'),('all','<task-notification>'),('all','[SYSTEM'),('all','[handback-send-enforce]'),('all','[Your'),
 ('all','[Cross-session'),('all','[external'),('all','[external_agent_tool_result]'),('all','[Usage'),('all','<pasted_content'),
 ('all','<recommended_plugins>'),('all','</environment_context>'),('all','</INSTRUCTIONS>'),('all','</task-notification>'),
 ('all','</system-reminder>'),('all','</pasted_content>')
), kind_map(user_kind, fixed_speaker) AS (VALUES ('compaction_summary','harness'), ('skill_body','harness'), ('tool_result_envelope','tool'), ('caller_brief','agent')),
keyed AS (SELECT *, CASE WHEN starts_with(prefix,'<') THEN ltrim(string_split(string_split(prefix,'>')[1],' ')[1],'<') ELSE string_split(prefix,' ')[1] END AS marker_lead FROM marker_map),
wrapper_sets AS (SELECT map_key, array_agg(token) AS match_array FROM wrapper_map GROUP BY map_key),
-- Length quantiles of user rows, kept as columns so later tiers and other readers can use them.
role_lengths AS (SELECT message_role, approx_quantile(content_length,.5) AS p50, approx_quantile(content_length,.95) AS p95,
 approx_quantile(content_length,.99) AS p99, count(id) AS role_rows FROM agent.stream WHERE message_role='user' GROUP BY message_role),
raw_src AS (SELECT id, system, session_id, parent_session_id, project_path, ts, day, file_name, line_number, p50, p95, p99, role_rows,
 message_content AS c, content_length, array_to_string([system,is_agent::VARCHAR,thread_source,originator],'|') AS launch_key, ltrim(c,chr(9)||chr(10)||chr(13)||' ') AS c_start, left(c_start,100) AS head, 'all' AS map_key,
 CASE WHEN starts_with(head,'<') THEN ltrim(string_split(string_split(head,'>')[1],' ')[1],'<') ELSE string_split(translate(head,chr(9)||chr(10)||chr(13),'   '),' ')[1] END AS lead
 FROM agent.stream JOIN role_lengths USING (message_role) WHERE message_role='user'),
src AS (SELECT s.* EXCLUDE(map_key,lead), w.match_array, s.lead FROM raw_src s JOIN wrapper_sets w USING(map_key)),
long_rows AS (SELECT id, [left(c_start,100),right(c_start,100)] AS long_ends,
 list_transform(long_ends,e -> len(array_intersect(string_split(trim(replace(replace(translate(e,chr(9)||chr(10)||chr(13),'   '),'<',' <'),'>','> ')),' '),match_array))=0) AS long_end_is_human
 FROM src WHERE c IS NOT NULL AND content_length>p95),
tiered AS (SELECT s.*, l.long_ends, l.long_end_is_human,
 CASE WHEN c IS NULL THEN false WHEN content_length<=50 THEN len(array_intersect(string_split(trim(replace(replace(translate(left(c,50),chr(9)||chr(10)||chr(13),'   '),'<',' <'),'>','> ')),' '),match_array))=0
      WHEN content_length<=p95 THEN true ELSE list_contains(long_end_is_human,true) END AS is_human
 FROM src s LEFT JOIN long_rows l USING(id)),
kinded AS (SELECT s.*, k.prefix, k.marker_kind, k.marker_speaker, k.open, k.close, l.launch_kind, string_split(c_start,k.open) AS by_open,
 CASE WHEN k.marker_kind IS NULL THEN c WHEN close IS NOT NULL THEN string_split(by_open[2],close)[1] WHEN strpos(c_start,open)>0 THEN substr(c_start,strpos(c_start,open)+length(open)) END AS wrapper_stripped,
 CASE WHEN c IS NULL THEN 'tool_result_envelope' WHEN contains(left(c,400),'This session is being continued from a previous conversation') THEN 'compaction_summary'
      WHEN is_human AND k.marker_kind IS NULL AND launch_kind IS NOT NULL THEN launch_kind
      WHEN contains(c,'<pasted_content id="') THEN 'paste' WHEN k.marker_kind IS NOT NULL THEN k.marker_kind WHEN contains(left(c,400),'<INSTRUCTIONS>') THEN 'agents_md_preamble'
      WHEN starts_with(c_start,'# ') AND contains(left(c_start,300),' Skill') THEN 'skill_body' WHEN is_human THEN 'typed' ELSE 'harness_text' END AS user_kind,
 string_split(wrapper_stripped,'<pasted_content id="') AS by_paste_open, list_transform(by_paste_open[2:],p -> string_split(p,'</pasted_content')) AS paste_parts,
 list_transform(paste_parts,p -> substr(p[1],strpos(p[1],'>')+1)) AS paste_bodies, list_transform(paste_parts,p -> substr(p[2],strpos(p[2],'>')+1)) AS paste_tails,
 CASE user_kind WHEN 'typed' THEN c WHEN 'paste' THEN by_paste_open[1]||' '||array_to_string(paste_tails,' ')
      WHEN 'image_prefixed' THEN CASE WHEN list_contains(list_transform(['[Image #','[Image:'],p -> starts_with(ltrim(wrapper_stripped),p)),true) THEN substr(wrapper_stripped,strpos(wrapper_stripped,']')+1) ELSE wrapper_stripped END
      WHEN 'harness_text' THEN NULL ELSE wrapper_stripped END AS raw_text,
 CASE WHEN trim(translate(raw_text,chr(9)||chr(10)||chr(13),''))<>'' THEN raw_text END AS words
 FROM tiered s LEFT JOIN keyed k ON s.lead=k.marker_lead AND starts_with(s.c_start,k.prefix) LEFT JOIN launch_map l ON s.launch_key=l.launch_key),
shaped AS (SELECT k.*, k.user_kind='typed' AND k.content_length>10000 AS over_cap, m.fixed_speaker, coalesce(marker_speaker,fixed_speaker) AS mapped_speaker FROM kinded k LEFT JOIN kind_map m USING(user_kind))
SELECT * EXCLUDE(marker_speaker,fixed_speaker,mapped_speaker,words), CASE WHEN mapped_speaker IN ('agent','harness','tool') OR over_cap THEN NULL ELSE words END AS user_text,
 CASE WHEN mapped_speaker='agent' THEN c END AS agent_text, CASE WHEN user_kind='paste' THEN array_to_string(paste_bodies,chr(10)||'---'||chr(10)) END AS paste_text,
 coalesce(mapped_speaker,CASE WHEN words IS NOT NULL OR paste_text IS NOT NULL THEN 'human' ELSE 'harness' END) AS speaker,
 CASE WHEN user_kind='paste' AND len(string_split(c,'<pasted_content id="'))<>len(string_split(c,'</pasted_content')) THEN 'unresolved: paste tags unbalanced'
      WHEN marker_kind=user_kind AND len(by_open)>2 AND user_kind<>'image_prefixed' THEN 'unresolved: opening tag repeated'
      WHEN marker_kind=user_kind AND close IS NOT NULL AND len(by_open)=1 THEN 'unresolved: opening tag missing'
      WHEN over_cap THEN 'filtered: over 10000' WHEN words IS NOT NULL OR paste_text IS NOT NULL OR agent_text IS NOT NULL THEN 'ok' ELSE 'no_words' END AS extract_status
FROM shaped;
-- Few, stable checks on the goal: one row per source id, and no user_text large enough to flood an agent's context.
WITH stats AS (SELECT len(array_agg(id)) AS n, len(array_agg(id))=len(array_agg(DISTINCT id)) AS unique_ok,
 count(user_text) AS text_n, bool_and(length(user_text)<=10000) AS bounded_ok, bool_and(speaker IS NOT NULL AND extract_status IS NOT NULL) AS labelled_ok FROM agent.user_text),
checks AS (SELECT unnest([{'rule':'source ids are unique','ok':unique_ok,'n':n}, {'rule':'user_text at most 10000 chars','ok':bounded_ok,'n':text_n},
 {'rule':'every row has a speaker and status','ok':labelled_ok,'n':n}]) AS r FROM stats),
asserted AS (SELECT r.*, CASE WHEN list_contains(array_agg(r.ok IS NOT TRUE) OVER (),true) THEN error('agent.user_text checks failed') ELSE true END AS all_ok FROM checks)
SELECT rule, CASE WHEN all_ok THEN ok END AS ok, n FROM asserted ORDER BY rule LIMIT 100$sql$ AS body),
dispatched AS (SELECT array_agg(http_post('http://localhost:9495/sql',MAP {'Content-Type':'application/json'},{'sql':body}::JSON)) AS responses FROM program)
SELECT r.status, r.body FROM dispatched CROSS JOIN UNNEST(responses) AS u(r);

-- Read-only Luna and worktree observability.  The views deliberately read the
-- agent_data/duck_tails relations and self-dispatch literal table-function
-- calls through the selected dev SQL door; they do not create state tables.

CREATE SCHEMA IF NOT EXISTS agents;

CREATE OR REPLACE VIEW agents.lunas AS
WITH conversations AS (
    SELECT *
    FROM read_conversations(source := 'codex', path := getenv('HOME') || '/.codex')
), conversation_sessions AS (
    SELECT session_id,
           min(TRY_CAST(timestamp AS TIMESTAMPTZ)) AS conversation_started,
           max(TRY_CAST(timestamp AS TIMESTAMPTZ)) AS conversation_last_ts,
           (array_agg(cwd ORDER BY TRY_CAST(timestamp AS TIMESTAMPTZ)) FILTER (cwd IS NOT NULL))[-1] AS conversation_cwd,
           (array_agg(message_content ORDER BY TRY_CAST(timestamp AS TIMESTAMPTZ))
                FILTER (message_role = 'assistant' AND message_content IS NOT NULL AND len(message_content) > 0))[-1][:300] AS conversation_last_message,
           count(DISTINCT tool_use_id) FILTER (tool_use_id IS NOT NULL) AS conversation_tool_call_count,
           sum(coalesce(input_tokens, 0)) AS input_tokens,
           sum(coalesce(cache_read_tokens, 0)) AS cached_tokens,
           sum(coalesce(output_tokens, 0)) AS output_tokens,
           sum(coalesce(reasoning_tokens, 0)) AS reasoning_tokens
    FROM conversations
    GROUP BY session_id
), stream_sessions AS (
    SELECT session_id,
           min(ts) AS stream_started,
           max(ts) AS stream_last_ts,
           (array_agg(cwd ORDER BY ts DESC) FILTER (cwd IS NOT NULL))[1] AS stream_cwd,
           (array_agg(parent_session_id ORDER BY ts DESC) FILTER (parent_session_id IS NOT NULL))[1] AS stream_parent_session_id,
           (array_agg(message_content ORDER BY ts DESC)
                FILTER (event_kind = 'agent_text' AND message_content IS NOT NULL))[1][:300] AS stream_last_message,
           max(ts) FILTER (
               event_kind = 'agent_text' AND message_type = 'assistant'
               AND status IN ('completed', 'final_answer')
           ) AS final_assistant_ts,
           max(ts) FILTER (
               status IN ('failed', 'error')
               OR stop_reason IN ('failed', 'error', 'interrupted')
               OR parse_error IS NOT NULL
           ) AS last_error_ts,
           (array_agg(coalesce(message_content, content_headtail) ORDER BY ts DESC) FILTER (
               status IN ('failed', 'error')
               OR stop_reason IN ('failed', 'error', 'interrupted')
               OR parse_error IS NOT NULL
           ))[1][:300] AS last_error,
           count(DISTINCT tool_use_id) FILTER (tool_use_id IS NOT NULL) AS tool_call_count,
           array_agg(DISTINCT model) FILTER (model IS NOT NULL) AS models,
           array_agg(DISTINCT reasoning_effort) FILTER (reasoning_effort IS NOT NULL) AS efforts
    FROM agent.stream
    WHERE system = 'codex' AND originator = 'codex_exec'
    GROUP BY session_id
), parent_context AS (
    SELECT session_id,
           (array_agg(system ORDER BY ts DESC) FILTER (system IS NOT NULL))[1] AS parent_system,
           (array_agg(cwd ORDER BY ts DESC) FILTER (cwd IS NOT NULL))[1] AS parent_cwd
    FROM agent.stream
    GROUP BY session_id
), sessions AS (
    SELECT c.session_id,
           coalesce(s.stream_cwd, c.conversation_cwd) AS cwd,
           coalesce(s.stream_started, c.conversation_started) AS started,
           coalesce(s.stream_last_ts, c.conversation_last_ts) AS last_ts,
           coalesce(s.stream_parent_session_id,
               CASE WHEN contains(coalesce(s.stream_cwd, c.conversation_cwd), '/parent=')
                    THEN split_part(split_part(coalesce(s.stream_cwd, c.conversation_cwd), '/parent=', 2), '/', 1)
               END) AS parent_session_id,
           coalesce(s.stream_last_message, c.conversation_last_message) AS last_message,
           c.input_tokens,
           c.cached_tokens,
           c.output_tokens,
           c.reasoning_tokens,
           coalesce(c.input_tokens, 0) + coalesce(c.cached_tokens, 0) + coalesce(c.output_tokens, 0) + coalesce(c.reasoning_tokens, 0) AS tokens,
           s.final_assistant_ts,
           s.last_error_ts,
           s.last_error,
           coalesce(s.tool_call_count, c.conversation_tool_call_count, 0) AS tool_call_count,
           s.models,
           s.efforts
    FROM conversation_sessions c
    LEFT JOIN stream_sessions s USING (session_id)
)
SELECT s.session_id,
       CASE WHEN contains(coalesce(s.cwd, ''), '/parent_system=')
            THEN split_part(split_part(s.cwd, '/parent_system=', 2), '/', 1)
            ELSE coalesce(p.parent_system, 'unknown') END AS parent_system,
       s.parent_session_id,
       coalesce(p.parent_cwd, s.cwd) AS parent_cwd,
       s.cwd,
       s.started,
       s.last_ts,
       CASE
           WHEN s.last_error_ts IS NOT NULL
                AND s.last_error_ts >= coalesce(s.final_assistant_ts, TIMESTAMPTZ '1970-01-01')
                AND s.last_error_ts >= s.last_ts - INTERVAL 1 SECOND THEN 'failed'
           WHEN s.final_assistant_ts IS NOT NULL
                AND s.final_assistant_ts >= s.last_ts - INTERVAL 1 SECOND THEN 'done'
           WHEN s.last_ts > now() - INTERVAL 10 MINUTE THEN 'running'
           WHEN s.last_error_ts IS NOT NULL THEN 'failed'
           ELSE 'stopped' END AS state,
       s.tokens,
       s.input_tokens,
       s.cached_tokens,
       s.output_tokens,
       s.reasoning_tokens,
       s.last_message,
       s.last_error,
       coalesce(s.tool_call_count, 0) AS tool_call_count,
       s.models,
       s.efforts
FROM sessions s
LEFT JOIN parent_context p ON p.session_id = s.parent_session_id;

CREATE OR REPLACE VIEW agents.luna_branches AS
WITH raw_worktrees AS (
    SELECT 'asubbarao/quackapi' AS repository,
           '/Users/aloksubbarao/reviews/asubbarao-since-2025-10-01/repos/quackapi' AS repository_root,
           content
    FROM read_text('git -C /Users/aloksubbarao/reviews/asubbarao-since-2025-10-01/repos/quackapi worktree list --porcelain |')
    UNION ALL
    SELECT 'asubbarao/duckstack', '/Users/aloksubbarao/duckdb-skills', content
    FROM read_text('git -C /Users/aloksubbarao/duckdb-skills worktree list --porcelain |')
), worktree_lines AS (
    SELECT repository, repository_root, line, ordinal
    FROM raw_worktrees
    CROSS JOIN UNNEST(string_split(content, chr(10))) WITH ORDINALITY AS u(line, ordinal)
), worktree_rows AS (
    SELECT repository,
           repository_root,
           substr(trim(line), len('worktree ') + 1) AS worktree,
           substr(trim(head_line), len('HEAD ') + 1) AS head_sha,
           CASE WHEN starts_with(trim(branch_line), 'branch refs/heads/')
                THEN substr(trim(branch_line), len('branch refs/heads/') + 1) END AS branch
    FROM (
        SELECT *,
               lead(line, 1) OVER (PARTITION BY repository ORDER BY ordinal) AS head_line,
               lead(line, 2) OVER (PARTITION BY repository ORDER BY ordinal) AS branch_line
        FROM worktree_lines
    ) w
    WHERE starts_with(trim(line), 'worktree ')
), quoted_worktrees AS (
    SELECT *,
           chr(39) || replace(worktree, chr(39), chr(39) || chr(39)) || chr(39) AS sql_worktree
    FROM worktree_rows
), statements AS (
    SELECT *,
           'WITH head AS (' ||
           'SELECT commit_hash AS head_sha, split_part(message, chr(10), 1) AS head_subject, ' ||
           'CASE WHEN strpos(message, chr(10) || chr(10)) > 0 ' ||
           'THEN substr(message, strpos(message, chr(10) || chr(10)) + 2) ELSE '''' END AS head_body ' ||
           'FROM git_log(repo_path := ' || sql_worktree || ') LIMIT 1), ' ||
           'diffs AS (' ||
           'SELECT file_path FROM git_diff_tree(' || sql_worktree || ', ''origin/main'', ''HEAD'', untracked := false)), ' ||
           'ahead AS (' ||
           'SELECT trim(content) AS ahead_of_main FROM read_text(' ||
           chr(39) || 'git -C ' || replace(worktree, chr(39), chr(39) || chr(92) || chr(39) || chr(39)) ||
           ' rev-list --count origin/main..HEAD |' || chr(39) || ')) ' ||
           'SELECT ''head'' AS kind, head_sha, head_subject, head_body, NULL::VARCHAR AS changed_file, NULL::VARCHAR AS ahead_of_main FROM head ' ||
           'UNION ALL SELECT ''diff'', NULL, NULL, NULL, file_path, NULL FROM diffs ' ||
           'UNION ALL SELECT ''ahead'', NULL, NULL, NULL, NULL, ahead_of_main FROM ahead' AS statement
    FROM quoted_worktrees
), receipts AS (
    SELECT *,
           http_post(coalesce(nullif(getenv('DUCKSTACK_SQL_URL'), ''), 'http://127.0.0.1:9495/sql'), MAP {'Content-Type': 'application/json'},
               json_object('sql', statement)) AS receipt
    FROM statements
), parsed AS (
    SELECT r.worktree, u.row.kind, u.row.head_sha, u.row.head_subject, u.row.head_body,
           u.row.changed_file, u.row.ahead_of_main
    FROM receipts r
    CROSS JOIN UNNEST(from_json(receipt ->> '$.body',
        '[{"kind":"VARCHAR","head_sha":"VARCHAR","head_subject":"VARCHAR","head_body":"VARCHAR","changed_file":"VARCHAR","ahead_of_main":"VARCHAR"}]')) AS u(row)
    WHERE receipt ->> '$.status' = '200'
), summary AS (
    SELECT r.repository,
           r.repository_root,
           r.worktree,
           r.branch,
           r.head_sha AS listed_head_sha,
           r.statement,
           r.receipt ->> '$.status' AS dispatch_status,
           r.receipt ->> '$.body' AS dispatch_body,
           max(p.head_sha) FILTER (p.kind = 'head') AS head_sha,
           max(p.head_subject) FILTER (p.kind = 'head') AS head_subject,
           max(p.head_body) FILTER (p.kind = 'head') AS head_body,
           list_filter(list(p.changed_file) FILTER (p.kind = 'diff'), x -> x IS NOT NULL) AS changed_files,
           count(p.changed_file) FILTER (p.kind = 'diff') AS changed_file_count,
           TRY_CAST(max(p.ahead_of_main) FILTER (p.kind = 'ahead') AS BIGINT) AS ahead_of_main
    FROM receipts r
    LEFT JOIN parsed p USING (worktree)
    GROUP BY ALL
)
SELECT s.repository,
       s.repository_root,
       s.worktree,
       s.branch,
       s.listed_head_sha,
       coalesce(s.head_sha, s.listed_head_sha) AS head_sha,
       s.head_subject,
       s.head_body,
       s.changed_files,
       s.changed_file_count,
       s.ahead_of_main,
       s.dispatch_status,
       s.dispatch_body,
       'gh pr create -R ' || s.repository || ' --head ' || coalesce(s.branch, '') ||
           ' --base main --title ' || chr(39) || replace(coalesce(s.head_subject, ''), chr(39), chr(39) || chr(92) || chr(39) || chr(39)) || chr(39) ||
           ' --body ' || chr(39) || replace(coalesce(s.head_body, ''), chr(39), chr(39) || chr(92) || chr(39) || chr(39)) || chr(39) AS pr_create_command,
       'gh pr merge -R ' || s.repository || ' ' || coalesce(s.branch, '') || ' --merge' AS pr_merge_command,
       l.session_id AS luna_session_id,
       l.state AS luna_state,
       l.tokens AS luna_tokens,
       l.last_ts AS luna_last_ts
FROM summary s
LEFT JOIN agents.lunas l ON l.cwd = s.worktree;

CREATE OR REPLACE VIEW agents.luna_prs AS
WITH prs AS (
    SELECT 'asubbarao/quackapi' AS repository, p.*
    FROM read_json(
        'gh pr list -R asubbarao/quackapi --state open --limit 100 --json number,title,headRefName,headRefOid,state,statusCheckRollup,url,baseRefName,headRepositoryOwner,headRepository |',
        format := 'array',
        columns := {
            number: 'INTEGER', title: 'VARCHAR', headRefName: 'VARCHAR', headRefOid: 'VARCHAR',
            state: 'VARCHAR',
            statusCheckRollup: 'STRUCT(name VARCHAR, context VARCHAR, conclusion VARCHAR, state VARCHAR, detailsUrl VARCHAR, targetUrl VARCHAR)[]',
            url: 'VARCHAR', baseRefName: 'VARCHAR',
            headRepositoryOwner: 'STRUCT(login VARCHAR)', headRepository: 'STRUCT(name VARCHAR)'
        }) p
    UNION ALL
    SELECT 'asubbarao/duckstack', p.*
    FROM read_json(
        'gh pr list -R asubbarao/duckstack --state open --limit 100 --json number,title,headRefName,headRefOid,state,statusCheckRollup,url,baseRefName,headRepositoryOwner,headRepository |',
        format := 'array',
        columns := {
            number: 'INTEGER', title: 'VARCHAR', headRefName: 'VARCHAR', headRefOid: 'VARCHAR',
            state: 'VARCHAR',
            statusCheckRollup: 'STRUCT(name VARCHAR, context VARCHAR, conclusion VARCHAR, state VARCHAR, detailsUrl VARCHAR, targetUrl VARCHAR)[]',
            url: 'VARCHAR', baseRefName: 'VARCHAR',
            headRepositoryOwner: 'STRUCT(login VARCHAR)', headRepository: 'STRUCT(name VARCHAR)'
        }) p
)
SELECT p.repository,
       p.number,
       p.title,
       p.headRefName AS head_branch,
       p.headRefOid AS head_sha,
       p.baseRefName AS base_branch,
       p.state,
       to_json(p.statusCheckRollup) AS checks,
       CASE WHEN len(list_filter(coalesce(p.statusCheckRollup, []),
                    x -> coalesce(x.conclusion, x.state) IN ('FAILURE', 'ERROR', 'TIMED_OUT', 'STARTUP_FAILURE', 'CANCELLED'))) > 0
            THEN 'failing' ELSE 'passing_or_pending' END AS checks_state,
       p.url,
       b.worktree,
       b.ahead_of_main,
       b.luna_session_id,
       b.luna_state,
       b.luna_tokens
FROM prs p
LEFT JOIN agents.luna_branches b
    ON b.repository = p.repository AND b.branch = p.headRefName;

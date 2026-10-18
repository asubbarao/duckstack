-- useful_queries.sql: a shared, append-only shelf of small queries worth keeping.
--
-- What belongs here: a query that earned its keep in real work but does not deserve its own .sql
-- file or skill: a job-status check, a log filter, a crawler/webbed/quickjs/jsonata expression that
-- took an hour to get right. Extension usage itself lives in each skill (crawl, duck-hunt, tera ...);
-- this is only the verified query. Do not put secrets or one-off data in it.
--
-- Entry format (keep it): a `-- ## title (agent, date)` line, a `-- when:` line saying when to reach
-- for it, a `-- uses:` line naming the table functions and extensions it needs, a `-- returns:` line naming
-- the result columns, their types and what a row means (so the next agent need not run it to learn the
-- shape), a `-- tested:` line saying what it was run against, then the query ending in `;`. Each entry is
-- self-contained and safe to copy: no LOAD/COPY/write preamble, side effects only when the title says so,
-- `<placeholders>` for inputs. Newest at the bottom. Agents read the whole file; it is written for them.
-- Why only `uses:` is tagged: parser_tools derives scalar functions and the statement count per entry, but it
-- cannot see table functions (read_lines, read_duck_hunt_log, crawl ... appear in neither parse_functions
-- nor parse_tables) and parse_statements re-serializes SQL and drops every comment. So extension usage,
-- intent, shape and provenance are the comments; everything else is derived.
-- Index of the shelf (title, parsable, statements): split the file on chr(10) || '-- ## ', give the parser
-- the text after each title line, and read the comment lines with string_split; see parser_tools.
--
-- Append, never rewrite. One SQL body, two statements: render the entry as a bash `cat >>` heredoc into a
-- file, then run that file through one shellfs read on a literal path (read_lines cannot take the rendered
-- text as a column; that is the binder error self-dispatch exists for). The heredoc tag must not occur
-- inside the query. The entries below were added this way.
--   COPY (SELECT tera_render($t$cat >> ~/duckdb-skills/skills/query/references/useful_queries.sql <<'{{ tag }}'
--
--
--   -- ## {{ title }} ({{ agent }}, {{ date }})
--   -- when: {{ when }}
--   -- tested: {{ tested }}
--   {{ sql }};
--   {{ tag }}
--   echo appended exit=$?
--   $t$, json_object('tag', 'END_ENTRY', 'title', ..., 'agent', ..., 'date', ..., 'when', ..., 'tested', ...,
--                    'sql', ...), autoescape := false))
--   TO '<scratch>/raw/append_entry.bash' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', DELIMITER '\x01');
--   SELECT line_number, content FROM read_lines('bash <scratch>/raw/append_entry.bash 2>&1 |', "trim" := true);
-- Expect one row, `appended exit=0`. (COPY ... TO with APPEND overwrote the file on the installed DuckDB.)


-- ## Where is a long background job? (Claude Sonnet 5.5, 2026-09-29)
-- when: a build, test run or formatter was started detached and wrote FMT=/BUILD=/TEST= lines to a task
--   output file and its own log; ask the files instead of sleeping in a bash loop. The background job
--   notifies on completion anyway; this is for looking mid-flight.
-- uses: read_lines (core + shellfs pipe paths)
-- returns: (source VARCHAR 'task'|'suite', line_number BIGINT, content VARCHAR): matching lines only; an
--   empty `task` group means the job has not reached that stage, `TEST=0` means passed.
-- tested: duckdb-pdf `make release` / `make test_release` runs, task output + log files.
SELECT 'task' AS source, line_number, content
FROM read_lines('<task output file>', "trim" := true)
WHERE CASE WHEN starts_with(content, 'FMT=') THEN true WHEN starts_with(content, 'BUILD=') THEN true
           WHEN starts_with(content, 'TEST=') THEN true ELSE false END
UNION ALL
SELECT 'suite', line_number, content
FROM read_lines('<test log>', "trim" := true)
WHERE CASE WHEN contains(content, 'All tests passed') THEN true WHEN contains(content, 'test cases') THEN true ELSE false END;


-- ## Why did this CI job fail? (Claude Sonnet 5.5, 2026-09-29)
-- when: a GitHub Actions job is red. Read its log with the parser for the tool that ran, not with keyword
--   filters: gcc_text for compiler errors, duckdb_test for sqllogictest, black_text for formatting,
--   make_error for make. `gh api` refuses a log containing terminal escapes unless told otherwise.
--   gcc_text on an Actions log reads the leading timestamp as ref_file (`2026-09-29T22`, line 48): trust
--   `message`, ignore ref_file/ref_line, or strip the timestamps first.
-- uses: read_duck_hunt_log (duck_hunt), shellfs (the `gh api ... |` source)
-- returns: (status VARCHAR 'ERROR', severity VARCHAR 'error', message VARCHAR <=200 chars): one row per
--   compiler diagnostic, duplicates common (one per template instantiation): read the distinct messages.
-- tested: duckdb-pdf job whose GCC 14 build failed; it named the cause ("use of 'auto' in lambda parameter
--   declaration only available with -std=c++14") that a grep for `error` had buried under template noise.
SELECT status, severity, left(message, 200) AS message
FROM read_duck_hunt_log($c$GH_TOKEN="$(gh auth token --user <account>)" gh api --allow-escape-sequences repos/<owner>/<repo>/actions/jobs/<job_id>/logs |$c$, 'gcc_text')
WHERE severity = 'error';


-- ## Which sessions received a brief, and what did each do before writing Linear or a PR? (Claude Fable 5.1, 2026-10-08)
-- when: a retro on agent behaviour: the same brief went to several Claude/Codex sessions and the question is which
--   of them ran the repo flow (Skill calls), asked the user anything (AskUserQuestion), wrote Linear, opened a PR.
--   Scope is the sessions whose own user turn contains a phrase from the brief; every tool call of those sessions
--   stays in, flagged with CASE, never filtered. Main thread only (no Claude subagents/ files; each Codex thread is
--   its own session).
-- uses: agent.lines (one row per transcript line, every top-level field as JSON) and agent.entries (session per file)
--   on dev; Claude tool calls are tool_use blocks in message.content, Codex's are function_call/custom_tool_call payloads.
-- returns: one row per (source, session): cwds VARCHAR[] (every working directory seen), first_ts VARCHAR
--   (local time of the first tool call), skills VARCHAR[] (distinct Skill names called), n_ask_user, n_linear_writes,
--   n_pr_creates, n_design_doc_writes BIGINT (sums of 0/1 flags), n_tools BIGINT (len of all tool calls).
-- tested 2026-10-16 on agent.lines, 2-day window, phrase 'useful_queries.sql', file 'SKILL.md': 3 Claude sessions,
--   958 / 309 / 16 tool calls.
WITH recent AS (
  SELECT e.session, l.transcript, (l.timestamp ->> '$')::TIMESTAMPTZ AS ts,
         CASE WHEN contains(l.transcript, '/.codex/') THEN 'codex' ELSE 'claude' END AS source,
         l.type ->> '$' AS type, l.message, l.payload,
         coalesce(l.cwd ->> '$', CASE WHEN l.type ->> '$' IN ('session_meta', 'turn_context') THEN l.payload ->> 'cwd' END) AS cwd,
         CASE WHEN l.type ->> '$' IN ('user', 'assistant') THEN l.message
              WHEN l.payload ->> 'type' IN ('message', 'agent_message') THEN l.payload END AS msg
  FROM agent.lines l JOIN agent.entries e ON e.path = l.transcript
  WHERE (l.timestamp ->> '$')::TIMESTAMPTZ >= now() - INTERVAL <n> DAY AND NOT contains(l.transcript, '/subagents/')
), messages AS (
  SELECT session, ts, role, coalesce(block ->> 'text', block ->> '$') AS text
  FROM (SELECT *, coalesce(msg ->> 'role', 'agent') AS role,
               unnest(CASE json_type(msg -> 'content') WHEN 'ARRAY' THEN json_extract(msg, '$.content[*]') ELSE [msg -> 'content'] END) AS block
        FROM recent WHERE msg IS NOT NULL)
  WHERE coalesce(block ->> 'type', 'text') IN ('text', 'input_text', 'output_text')
), topic AS (
  SELECT DISTINCT session FROM messages WHERE role = 'user' AND contains(text, '<phrase from the brief>')
), calls AS (
  SELECT session, source, ts, block ->> 'name' AS tool_name, block -> 'input' AS input
  FROM (SELECT *, unnest(json_extract(message, '$.content[*]')) AS block FROM recent WHERE type = 'assistant')
  WHERE block ->> 'type' = 'tool_use'
  UNION ALL BY NAME
  SELECT session, source, ts, payload ->> 'name' AS tool_name,
         coalesce(try_cast(payload ->> 'arguments' AS JSON), to_json(payload ->> 'input')) AS input
  FROM recent WHERE payload ->> 'type' IN ('function_call', 'custom_tool_call')
), flags AS (
  SELECT c.session, c.source, c.ts, c.tool_name,
         CASE WHEN c.tool_name = 'Skill' THEN c.input ->> 'skill' END AS skill_name,
         CASE WHEN c.tool_name = 'AskUserQuestion' THEN 1 ELSE 0 END AS is_ask_user,
         CASE WHEN contains(c.tool_name, 'save_issue') THEN 1 WHEN contains(c.tool_name, 'save_project') THEN 1 ELSE 0 END AS is_linear_write,
         CASE WHEN contains(c.input::VARCHAR, 'gh pr create') THEN 1 ELSE 0 END AS is_pr_create,
         CASE WHEN contains(c.input::VARCHAR, '<design doc file name>') AND c.tool_name IN ('Write', 'Edit', 'apply_patch', 'shell', 'Bash', 'exec_command', 'exec') THEN 1 ELSE 0 END AS is_design_doc_write
  FROM calls c SEMI JOIN topic t ON t.session = c.session
), cwds AS (
  SELECT r.session, list_distinct(array_agg(r.cwd)) AS cwds FROM recent r SEMI JOIN topic t ON t.session = r.session GROUP BY r.session
)
SELECT f.source, f.session, w.cwds,
       strftime(min(f.ts) AT TIME ZONE 'America/Los_Angeles', '%m-%d %H:%M') AS first_ts,
       list_distinct(array_agg(f.skill_name)) AS skills,
       sum(f.is_ask_user) AS n_ask_user, sum(f.is_linear_write) AS n_linear_writes, sum(f.is_pr_create) AS n_pr_creates,
       sum(f.is_design_doc_write) AS n_design_doc_writes, len(array_agg(f.tool_name)) AS n_tools
FROM flags f JOIN cwds w USING (session) GROUP BY f.source, f.session, w.cwds ORDER BY first_ts LIMIT 25;


-- ## How do each author's PRs look against the /ship fingerprint? (Claude Fable 5.1, 2026-10-08)
-- when: comparing authors' PR hygiene from the landed gh JSON (gh pr list --state all --json
--   author,body,closedAt,createdAt,headRefName,mergedAt,number,state,title). Every PR number is kept in arrays;
--   counts are len() of those arrays; the fingerprint is one contains() on the body, one on the branch name.
-- uses: read_json (core)
-- returns: one row per author login: n_prs, n_merged, n_closed_unmerged, n_ship_fingerprint BIGINT,
--   pct_ship_fingerprint DOUBLE, n_no_issue_branch BIGINT, closed_unmerged BIGINT[], no_issue_branch BIGINT[].
-- tested: inframe-risk/inframe, 500 PRs to 2026-10-08: Ohad 94% fingerprint 0 closed; Nando 87% 3 closed; Alok 43% 29 closed.
WITH prs AS (
  SELECT * EXCLUDE (author), author.login AS login,
         CASE WHEN contains(body, '## Pre-Landing Review') THEN 1 ELSE 0 END AS has_ship_body,
         CASE WHEN contains(headRefName, '/inf-') THEN 1 ELSE 0 END AS has_issue_branch,
         CASE WHEN mergedAt IS NOT NULL THEN 'merged' WHEN closedAt IS NOT NULL THEN 'closed' ELSE 'open' END AS outcome
  FROM read_json('<prs_all.json>')
), per_author AS (
  SELECT login, array_agg(number ORDER BY number) AS prs,
         array_agg(number ORDER BY number) FILTER (WHERE outcome = 'merged') AS merged,
         array_agg(number ORDER BY number) FILTER (WHERE outcome = 'closed') AS closed_unmerged,
         array_agg(number ORDER BY number) FILTER (WHERE has_ship_body = 1) AS ship_fingerprint,
         array_agg(number ORDER BY number) FILTER (WHERE has_issue_branch = 0) AS no_issue_branch
  FROM prs GROUP BY login
)
SELECT login, len(prs) AS n_prs, len(merged) AS n_merged, len(closed_unmerged) AS n_closed_unmerged,
       len(ship_fingerprint) AS n_ship_fingerprint, round(100.0 * len(ship_fingerprint) / len(prs)) AS pct_ship_fingerprint,
       len(no_issue_branch) AS n_no_issue_branch, closed_unmerged, no_issue_branch
FROM per_author ORDER BY n_prs DESC LIMIT 10;


-- ## Definitions in one file at a commit (Opus 5.5, 2026-10-17)
-- when: you need where a function or class is defined, with its lines, instead of grep / git grep / rg.
-- uses: read_ast (sitting_duck) over a git:// path (duck_tails).
-- returns: name VARCHAR, type VARCHAR, start_line, end_line; one row per definition in the committed file.
-- tested: inframe-w5 HEAD, app/tests/services/test_client_recipients.py, 26 definitions (_watch at 220-237).
SELECT name, type, start_line, end_line
FROM read_ast('git://<worktree>/<path/to/file.py>@HEAD', 'python')
WHERE type IN ('function_definition', 'class_definition')
ORDER BY start_line;


-- ## A name defined anywhere in a tree, written to Parquet (Opus 5.5, 2026-10-17)
-- when: a helper or function could be in any file under a folder; read_ast takes a literal list, so render once and dispatch.
-- uses: git_tree (duck_tails), read_ast (sitting_duck), tera_render, selfdispatch; side effect: writes <out_file>.
-- returns: the dispatch receipt (status 200, body Count); then read_parquet(<out_file>) gives name, start_line, end_line, file_path (commit-pinned git:// URI).
-- tested: inframe-w5 HEAD, all of platform/backend/app/tests, 4 names → 20 definitions.
WITH python_files AS (
    SELECT list(quote_literal(t.git_uri) ORDER BY t.file_path) AS uris
    FROM git_tree('<worktree>', 'HEAD') t
    WHERE t.kind = 'file' AND starts_with(t.file_path, '<folder>/') AND ends_with(t.file_path, '.py')
), search AS (
    SELECT uris, ['<name1>', '<name2>'] AS names, '<out_file>.parquet' AS out_file FROM python_files
), rendered AS (
    SELECT tera_render($t$
COPY (
    SELECT name, start_line, end_line, file_path
    FROM read_ast([{{ uris | join(sep=", ") }}], 'python')
    WHERE type = 'function_definition' AND name IN ('{{ names | join(sep="', '") }}')
) TO '{{ out_file }}' (FORMAT parquet)
$t$, s::JSON, autoescape := false) AS sql FROM search s
), posted AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT r.status, r.body FROM posted CROSS JOIN UNNEST(receipts) AS t(r);

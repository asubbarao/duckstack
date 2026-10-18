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
-- Index of the shelf (title, parsable, statements): split the file on e'\n-- ## ', give the parser the text
-- after each title line, and read the comment lines with string_split; see parser_tools.
--
-- Append at the bottom with a Bash heredoc or the editor (files are written directly, not assembled in SQL).
-- Every entry is in the house shape: values declared in the first CTE, a template that only substitutes,
-- array_agg(selfdispatch(sql)) then receipt.*; no FILTER, no lateral joins, no OR chains.


-- ## Where is a long background job? (Claude Sonnet 5.5, 2026-09-29)
-- when: a build, test run or formatter was started detached and wrote FMT=/BUILD=/TEST= lines to a task
--   output file and its own log; ask the files instead of sleeping in a bash loop. The background job
--   notifies on completion anyway; this is for looking mid-flight.
-- uses: read_lines, tera_render, selfdispatch
-- returns: one receipt per file; its body holds (source VARCHAR 'task'|'suite', line_number BIGINT, content VARCHAR)
--   for the matching lines only; an empty `task` body means the job has not reached that stage, `TEST=0` means passed.
-- tested: duckdb-pdf `make release` / `make test_release` runs; reshaped 2026-10-17 and rerun on two fixture files.
WITH logs AS (
    SELECT 'task' AS source, '<task output file>' AS path, $m$['FMT=', 'BUILD=', 'TEST=']$m$ AS markers
    UNION ALL
    SELECT 'suite', '<test log>', $m$['All tests passed', 'test cases']$m$
), rendered AS (
    SELECT tera_render($t$
        SELECT '{{ source }}' AS source, line_number, content
        FROM read_lines('{{ path }}', "trim" := true)
        WHERE len(list_filter({{ markers }}, m -> contains(content, m))) > 0
    $t$, l::JSON, autoescape := false) AS sql
    FROM logs AS l
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);


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
--   958 / 309 / 16 tool calls. Rerun 2026-10-17 after the content unnest became a TRY_CAST to JSON[]: 1-day window, 3 sessions.
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
               unnest(coalesce(TRY_CAST(msg -> 'content' AS JSON[]), [msg -> 'content'])) AS block
        FROM recent WHERE msg IS NOT NULL)
  WHERE coalesce(block ->> 'type', 'text') IN ('text', 'input_text', 'output_text')
), topic AS (
  SELECT DISTINCT session FROM messages WHERE role = 'user' AND contains(text, '<phrase from the brief>')
), calls AS (
  SELECT session, source, ts, block ->> 'name' AS tool_name, block -> 'input' AS input
  FROM (SELECT *, unnest(TRY_CAST(message -> 'content' AS JSON[])) AS block FROM recent WHERE type = 'assistant')
  WHERE block ->> 'type' = 'tool_use'
  UNION ALL BY NAME
  SELECT session, source, ts, payload ->> 'name' AS tool_name,
         coalesce(try_cast(payload ->> 'arguments' AS JSON), to_json(payload ->> 'input')) AS input
  FROM recent WHERE payload ->> 'type' IN ('function_call', 'custom_tool_call')
), flags AS (
  SELECT c.session, c.source, c.ts, c.tool_name,
         CASE WHEN c.tool_name = 'Skill' THEN c.input ->> 'skill' END AS skill_name,
         CASE WHEN c.tool_name = 'AskUserQuestion' THEN 1 ELSE 0 END AS is_ask_user,
         CASE WHEN len(list_filter(['save_issue', 'save_project'], w -> contains(c.tool_name, w))) > 0 THEN 1 ELSE 0 END AS is_linear_write,
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
-- reshaped 2026-10-17 (list comprehensions instead of FILTER), rerun on 500 PRs: ohad 95%, Nando 82%, asubbarao-ifr 60%.
WITH prs AS (
  SELECT * EXCLUDE (author), author.login AS login,
         contains(body, '## Pre-Landing Review') AS has_ship_body,
         contains(headRefName, '/inf-') AS has_issue_branch,
         CASE WHEN mergedAt IS NOT NULL THEN 'merged' WHEN closedAt IS NOT NULL THEN 'closed' ELSE 'open' END AS outcome
  FROM read_json('<prs_all.json>')
), per_author AS (
  SELECT login, array_agg({number: number, outcome: outcome, ship: has_ship_body, issue_branch: has_issue_branch} ORDER BY number) AS prs
  FROM prs GROUP BY login
), lists AS (
  SELECT login, prs,
         [p.number FOR p IN prs IF p.outcome = 'merged'] AS merged,
         [p.number FOR p IN prs IF p.outcome = 'closed'] AS closed_unmerged,
         [p.number FOR p IN prs IF p.ship] AS ship_fingerprint,
         [p.number FOR p IN prs IF NOT p.issue_branch] AS no_issue_branch
  FROM per_author
)
SELECT login, len(prs) AS n_prs, len(merged) AS n_merged, len(closed_unmerged) AS n_closed_unmerged,
       len(ship_fingerprint) AS n_ship_fingerprint, round(100.0 * len(ship_fingerprint) / len(prs)) AS pct_ship_fingerprint,
       len(no_issue_branch) AS n_no_issue_branch, closed_unmerged, no_issue_branch
FROM lists ORDER BY n_prs DESC LIMIT 10;


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
    SELECT list(quote_literal(git_uri) ORDER BY file_path) AS uris
    FROM git_tree('<worktree>', 'HEAD')
    WHERE kind = 'file' AND starts_with(file_path, '<folder>/') AND ends_with(file_path, '.py')
), search AS (
    SELECT uris, list_transform(['<name1>', '<name2>'], n -> quote_literal(n)) AS names,
           '<out_file>.parquet' AS out_file
    FROM python_files
), rendered AS (
    SELECT tera_render($t$
COPY (
    SELECT name, start_line, end_line, file_path
    FROM read_ast([{{ uris | join(sep=", ") }}], 'python')
    WHERE type = 'function_definition' AND name IN ({{ names | join(sep=", ") }})
) TO '{{ out_file }}' (FORMAT parquet)
$t$, s::JSON, autoescape := false) AS sql FROM search AS s
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);
-- rerun 2026-10-17 on inframe HEAD app/tests with the names prequoted in SQL: Count 2.
-- ## inframe test files with their last pytest run, per checkout (entries-style, PR #1576)
-- when: comparing test timings across worktrees. List the checkouts and their JUnit paths; nothing else changes.
--   Each checkout's run writes JUnit to platform/backend/.pytest_cache/junit.xml (git-ignored), e.g.
--   `uv run pytest app/tests/ -q --junitxml=.pytest_cache/junit.xml`. A checkout with no run sends nothing.
-- uses: duck_tails (git_tree), duck_hunt (read_duck_hunt_log 'junit_xml'), tera_render, selfdispatch.
-- returns: one receipt per checkout; its body holds (checkout, file_path, tests_run, failed BIGINT, secs DOUBLE).
-- tested 2026-10-15: inframe-w1 INF-1598 full suite 22,383 passed; reshaped to self-dispatch 2026-10-17 and rerun:
--   same slowest file, test_acord_gl_print_bugs.py 27.5s.
WITH checkouts AS (
    SELECT '/Users/aloksubbarao/inframe-w1' AS checkout, '/Users/aloksubbarao/inframe-w1/platform/backend/.pytest_cache/junit.xml' AS junit
    UNION ALL
    SELECT '/Users/aloksubbarao/inframe', '/Users/aloksubbarao/inframe/platform/backend/.pytest_cache/junit.xml'
), with_runs AS (
    SELECT * FROM checkouts WHERE path_exists(junit)
), rendered AS (
    SELECT tera_render($t$
        WITH tests AS (
            SELECT file_path, replace(replace(replace(file_path, 'platform/backend/', ''), '.py', ''), '/', '.') AS module
            FROM git_tree('{{ checkout }}', 'HEAD')
            WHERE kind = 'file' AND file_path LIKE 'platform/backend/app/tests/%test_%.py'
        ), events AS (
            SELECT * FROM read_duck_hunt_log('{{ junit }}', 'junit_xml')
        )
        SELECT '{{ checkout }}' AS checkout, tests.file_path,
               count(events.test_name) AS tests_run,
               count(CASE WHEN events.status = 'FAIL' THEN events.test_name END) AS failed,
               round(sum(events.execution_time), 2) AS secs
        FROM tests LEFT JOIN events ON starts_with(events.ref_file || '.', tests.module || '.')
        GROUP BY ALL
        ORDER BY secs DESC NULLS LAST
        LIMIT 7
    $t$, c::JSON, autoescape := false) AS sql
    FROM with_runs AS c
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);


-- ## The last 200 transcript lines of every Claude CLI session open in Terminal (Opus 5.5, 2026-10-17)
-- tested: 4 receipts, all 200.
WITH c AS (
    SELECT name, getenv('HOME') AS home, replace(cwd, '/', '-') AS project, sessionId AS session_id
    FROM terminal_sessions WHERE sessionId IS NOT NULL
), rendered AS (
    SELECT tera_render($tera$
        SELECT * FROM read_json($cmd$tail -n 200 "{{ home }}/.claude/projects/{{ project }}/{{ session_id }}.jsonl" |$cmd$,
                                format := 'newline_delimited')
    $tera$, c::JSON, autoescape := false) AS sql
    FROM c
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

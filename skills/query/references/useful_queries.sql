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

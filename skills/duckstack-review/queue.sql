-- duckstack review queue, one tick. launchd (com.inframe.duckstack-review.plist, beside this file) runs it every
-- minute from ~/.duck/deploy, the checkout of main:  duckdb :memory: -f skills/duckstack-review/queue.sql
-- Each open, non-draft PR by asubbarao on asubbarao/duckstack gets two statuses on its head commit, both required by
-- main's branch protection:
--   duckstack/rules   gate.sql: the hook's own checks on every changed .sql file and ```sql block;
--   duckstack/review  Opus 5.5, headless and without tools, given the duckstack-review skill, RULES.md and the
--                     manifesto plus the lines the PR adds. It runs in the background; a later tick posts its verdict.
-- Every PR gets auto-merge, so GitHub merges it once both are green and it is up to date with main. The state is the
-- statuses on GitHub and the prompt and result files in ~/.duck/review; a new push is a new head and is reviewed again.
-- Every GitHub call and the review's launch is one generated statement, self-dispatched to dev.
.output /dev/null
LOAD duck_tails;
LOAD shellfs;
LOAD scalarfs;
LOAD tera;
SELECT * FROM read_lines('mkdir -p /Users/aloksubbarao/.duck/review/prompts /Users/aloksubbarao/.duck/review/results; cp -n skills/duckstack-review/review_seed.json /Users/aloksubbarao/.duck/review/results/0-seed.json; git -C /Users/aloksubbarao/duckdb-skills fetch -q origin +refs/heads/main:refs/remotes/origin/main ''+refs/pull/*/head:refs/remotes/origin/pr/*'' 2>&1 |');

-- The PR list is read once into a ScalarFS variable: every view below refers to it, and a reader in a view runs
-- again at each reference. The seed is one draft row, so read_json has the list's shape when no PR is open.
COPY (SELECT * FROM read_json(['skills/duckstack-review/queue_seed.json',
                               'GH_TOKEN=$(/opt/homebrew/bin/gh auth token --user asubbarao) /opt/homebrew/bin/gh pr list --repo asubbarao/duckstack --state open --author asubbarao --json number,title,headRefOid,isDraft,autoMergeRequest,statusCheckRollup |'],
                              union_by_name := true))
TO 'variable:open_prs.json' (FORMAT json);
CREATE OR REPLACE VIEW open_prs AS
SELECT number AS pr_number, title, headRefOid AS head_sha, concat_ws('-', number, left(headRefOid, 12)) AS review_key,
       autoMergeRequest IS NOT NULL AS auto_merge,
       upper(list_filter(statusCheckRollup, s -> s.context = 'duckstack/rules')[1].state) AS rules_state,
       upper(list_filter(statusCheckRollup, s -> s.context = 'duckstack/review')[1].state) AS review_state,
       'GH_TOKEN=$(/opt/homebrew/bin/gh auth token --user asubbarao) /opt/homebrew/bin/gh' AS gh
FROM read_json('variable:open_prs.json')
WHERE NOT isDraft;

-- What each PR changes since it left main: base = the newest commit of the PR's history that main also has.
CREATE OR REPLACE VIEW pr_changes AS
WITH main_history AS (
    SELECT commit_hash FROM git_log('/Users/aloksubbarao/duckdb-skills', 'origin/main')
), pr_history AS (
    SELECT open_prs.pr_number, open_prs.head_sha, pr_log.commit_hash, pr_log.commit_date
    FROM open_prs CROSS JOIN LATERAL git_log_each('/Users/aloksubbarao/duckdb-skills', open_prs.head_sha) AS pr_log
), pr_bases AS (
    SELECT pr_number, head_sha, arg_max(commit_hash, commit_date) AS base_sha
    FROM pr_history SEMI JOIN main_history USING (commit_hash) GROUP BY pr_number, head_sha
)
SELECT pr_bases.pr_number, pr_bases.head_sha, pr_bases.base_sha, changed.file_path, changed.status
FROM pr_bases CROSS JOIN LATERAL git_diff_tree_each('/Users/aloksubbarao/duckdb-skills', pr_bases.base_sha, pr_bases.head_sha) AS changed;

CREATE OR REPLACE VIEW pr_files AS
SELECT pr_changes.pr_number, pr_changes.file_path, pr_changes.status, blob.text AS content
FROM pr_changes CROSS JOIN LATERAL git_read_each(git_uri('/Users/aloksubbarao/duckdb-skills', pr_changes.file_path, pr_changes.head_sha)) AS blob
WHERE pr_changes.status <> 'deleted' AND blob.is_text;

.read skills/duckstack-review/gate.sql

-- The lines a PR adds: a line counts as added when the new file holds more copies of it than the old one.
CREATE OR REPLACE VIEW pr_added_lines AS
WITH new_lines AS (
    SELECT pr_number, file_path, split.line_number, split.line,
           row_number() OVER (PARTITION BY pr_number, file_path, split.line ORDER BY split.line_number) AS copy_number
    FROM pr_files CROSS JOIN UNNEST(string_split(content, E'\n')) WITH ORDINALITY AS split(line, line_number)
), old_lines AS (
    SELECT pr_changes.pr_number, pr_changes.file_path, old.line, count(old.line) AS copies
    FROM pr_changes CROSS JOIN LATERAL git_read_each(git_uri('/Users/aloksubbarao/duckdb-skills', pr_changes.file_path, pr_changes.base_sha)) AS blob
    CROSS JOIN UNNEST(string_split(blob.text, E'\n')) AS old(line)
    WHERE pr_changes.status = 'modified' AND blob.is_text
    GROUP BY ALL
)
SELECT new_lines.pr_number, new_lines.file_path, new_lines.line_number, new_lines.line
FROM new_lines LEFT JOIN old_lines USING (pr_number, file_path, line)
WHERE new_lines.copy_number > coalesce(old_lines.copies, 0);

-- One prompt per PR that passed the rules and has no review yet; the launch command puts the rubric in front of it.
CREATE OR REPLACE VIEW review_prompts AS
WITH added_by_file AS (
    SELECT pr_number, file_path, string_agg(concat_ws(': ', line_number, line), E'\n' ORDER BY line_number) AS added
    FROM pr_added_lines GROUP BY pr_number, file_path
), file_sections AS (
    SELECT pr_files.pr_number, pr_files.file_path,
           tera_render($t$## {{ file_path }} ({{ status }})

Lines this PR adds, as line: text
{{ added }}

The whole file after the PR
{{ content }}
$t$, json_object('file_path', pr_files.file_path, 'status', pr_files.status, 'added', added_by_file.added, 'content', pr_files.content),
                       autoescape := false) AS section
    FROM pr_files JOIN added_by_file USING (pr_number, file_path)
), warnings AS (
    SELECT pr_number, string_agg(concat_ws(' ', file_path, check_id, message), E'\n') AS warnings
    FROM pr_rule_hits WHERE action = 'warn' GROUP BY pr_number
)
SELECT open_prs.review_key,
       tera_render('review_prompt.tera',
                   json_object('number', open_prs.pr_number, 'title', open_prs.title, 'warnings', coalesce(warnings.warnings, 'none'),
                               'files', string_agg(file_sections.section, E'\n' ORDER BY file_sections.file_path)),
                   autoescape := false, template_path := 'skills/duckstack-review/*.tera') AS prompt
FROM open_prs JOIN file_sections USING (pr_number) LEFT JOIN warnings USING (pr_number)
WHERE open_prs.rules_state = 'SUCCESS' AND open_prs.review_state IS NULL
GROUP BY open_prs.review_key, open_prs.pr_number, open_prs.title, warnings.warnings;

-- One prompt file per PR, prompts/review_key=<pr>-<sha>/data_0.csv, written raw (no quoting, no header).
COPY (SELECT review_key, prompt FROM review_prompts)
TO '/Users/aloksubbarao/.duck/review/prompts'
(FORMAT csv, HEADER false, QUOTE '', ESCAPE '', DELIMITER E'\x1f', PARTITION_BY (review_key), OVERWRITE_OR_IGNORE true);

-- Finished reviews, keyed by file name. The seed is there so the glob always matches.
CREATE OR REPLACE VIEW review_results AS
SELECT parse_filename(filename, true) AS review_key, is_error,
       structured_output.verdict AS verdict, structured_output.findings AS findings
FROM read_json('/Users/aloksubbarao/.duck/review/results/*.json', filename := true, union_by_name := true, ignore_errors := true);

-- Every call this tick makes: one row per PR and command.
CREATE OR REPLACE VIEW queue_commands AS
WITH rules_lines AS (
    SELECT pr_number, bool_or(action = 'block') AS blocked,
           string_agg(concat_ws(' ', '-', concat('**', action, '**'), concat('`', check_id, '`'), 'in', file_path, '-', message), E'\n'
                      ORDER BY action, file_path) AS lines
    FROM pr_rule_hits GROUP BY pr_number
), rules_due AS (
    SELECT open_prs.pr_number, open_prs.head_sha, open_prs.gh, coalesce(rules_lines.blocked, false) AS blocked, rules_lines.lines
    FROM open_prs LEFT JOIN rules_lines USING (pr_number)
    WHERE open_prs.rules_state IS NULL
), review_due AS (
    SELECT pr_number, head_sha, gh, review_key FROM open_prs WHERE rules_state = 'SUCCESS' AND review_state IS NULL
), finding_lines AS (
    SELECT review_key, string_agg(concat_ws(' ', '-', concat('`', finding.file, ':', finding.line, '`'), concat('**', finding.rule, '**'),
                                            finding.problem, E'\n  Rewrite:', finding.rewrite), E'\n') AS lines
    FROM review_results CROSS JOIN UNNEST(findings) AS each_finding(finding)
    WHERE finding.file <> '' GROUP BY review_key
), review_done AS (
    SELECT open_prs.pr_number, open_prs.head_sha, open_prs.gh,
           CASE review_results.verdict WHEN 'clean' THEN 'success' WHEN 'changes' THEN 'failure' ELSE 'error' END AS state,
           finding_lines.lines
    FROM open_prs JOIN review_results USING (review_key) LEFT JOIN finding_lines USING (review_key)
    WHERE open_prs.review_state = 'PENDING'
), comments AS (
    SELECT pr_number, gh, tera_render($t$**duckstack/rules: {{ verdict }}**

{{ lines }}

_duckstack review queue, rule gate (hooks/hook_checks.sql)_$t$,
           json_object('verdict', CASE WHEN blocked THEN 'blocked' ELSE 'passed with warnings' END, 'lines', lines), autoescape := false) AS body
    FROM rules_due WHERE lines IS NOT NULL
    UNION ALL
    SELECT pr_number, gh, tera_render($t$**duckstack/review: {{ state }}**

{{ lines }}

_Opus 5.5, duckstack review queue (duckstack-review skill)_$t$,
           json_object('state', state, 'lines', coalesce(lines, 'No findings.')), autoescape := false) AS body
    FROM review_done
)
SELECT pr_number, concat_ws(' ', gh, 'api', concat('repos/asubbarao/duckstack/statuses/', head_sha), '-f context=duckstack/rules',
                            CASE WHEN blocked THEN '-f state=failure -f description="Blocking rule hits; see the PR comment"'
                                 ELSE '-f state=success -f description="No blocking rule hits"' END) AS command
FROM rules_due
UNION ALL
SELECT pr_number, concat_ws(' ', gh, 'pr comment', pr_number, '--repo asubbarao/duckstack --body',
                            concat($q$'$q$, replace(body, $q$'$q$, $q$'"'"'$q$), $q$'$q$))
FROM comments
UNION ALL
SELECT pr_number, concat_ws(' ', gh, 'api', concat('repos/asubbarao/duckstack/statuses/', head_sha),
                            '-f context=duckstack/review -f state=pending -f description="Opus 5.5 is reviewing"')
FROM review_due
UNION ALL
SELECT pr_number, concat_ws(' ', '(cd /Users/aloksubbarao/.duck/review && cat',
                            '/Users/aloksubbarao/.duck/deploy/skills/duckstack-review/SKILL.md',
                            '/Users/aloksubbarao/.duck/deploy/skills/self-dispatch/RULES.md',
                            '/Users/aloksubbarao/.duck/deploy/SQL-MANIFESTO.md',
                            concat('prompts/review_key=', review_key, '/data_0.csv'),
                            '| /Users/aloksubbarao/.local/bin/claude -p --model claude-opus-5-5 --tools "" --output-format json',
                            '--no-session-persistence --strict-mcp-config --disable-slash-commands',
                            $q$--settings '{"disableAllHooks": true}'$q$,
                            '--json-schema "$(cat /Users/aloksubbarao/.duck/deploy/skills/duckstack-review/review_schema.json)"',
                            concat('> results/', review_key, '.part 2>&1; mv results/', review_key, '.part results/', review_key, '.json)'),
                            '> /dev/null 2>&1 & echo $!')
FROM review_due
UNION ALL
SELECT pr_number, concat_ws(' ', gh, 'api', concat('repos/asubbarao/duckstack/statuses/', head_sha), '-f context=duckstack/review',
                            concat('-f state=', state), CASE state WHEN 'success' THEN '-f description="Opus 5.5: clean"'
                                                                   WHEN 'failure' THEN '-f description="Opus 5.5: changes needed; see the PR comment"'
                                                                   ELSE '-f description="The review did not finish; push again to rerun"' END)
FROM review_done
UNION ALL
SELECT pr_number, concat_ws(' ', gh, 'pr merge', pr_number, '--repo asubbarao/duckstack --auto --merge')
FROM open_prs WHERE NOT auto_merge;

.output stdout
WITH commands AS (
    SELECT pr_number, 'read_text' AS reader, [concat(command, ' |')] AS sources, '' AS options FROM queue_commands
), rendered AS (
    SELECT pr_number, tera_render('shell.tera', c::JSON, autoescape := false,
                                  template_path := 'skills/self-dispatch/templates/*.tera') AS sql
    FROM commands AS c
), dispatched AS (
    SELECT array_agg({pr_number: pr_number, receipt: selfdispatch(sql)}) AS receipts FROM rendered
)
SELECT now() AS ticked_at, sent.pr_number, sent.receipt.status, left(sent.receipt.error, 200) AS error
FROM dispatched CROSS JOIN UNNEST(receipts) AS each_receipt(sent);

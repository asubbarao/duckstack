-- duckstack review queue, one tick. launchd (com.inframe.duckstack-review.plist, beside this file) runs it every
-- three minutes from ~/.duck/deploy, the checkout of main, with GH_TOKEN set to asubbarao's token.
-- Each open, non-draft PR by asubbarao on asubbarao/duckstack gets two statuses on its head commit, both required by
-- main's branch protection:
--   duckstack/rules   gate.sql: the hook's own checks on every changed .sql file and ```sql block;
--   duckstack/review  Opus 5.5, headless and without tools, given the duckstack-review skill, RULES.md and the
--                     manifesto plus the PR's description and the lines it adds. It runs in the background on dev;
--                     a later tick reads its result file and posts the verdict.
-- Statuses, comments and auto-merge are JSON posts to GitHub's API; GitHub merges a PR once both statuses are green.
-- The state is the statuses on GitHub and the files in ~/.duck/review; a new push is a new head and is checked again.
.output /dev/null
LOAD duck_tails;
LOAD hostfs;
LOAD shellfs;
LOAD scalarfs;
LOAD tera;
LOAD markdown;
SELECT * FROM read_lines($cmd$mkdir -p /Users/aloksubbarao/.duck/review/results; git -C /Users/aloksubbarao/duckdb-skills fetch -q origin +refs/heads/main:refs/remotes/origin/main '+refs/pull/*/head:refs/remotes/origin/pr/*' 2>&1 |$cmd$);

-- The PR list is read once into a ScalarFS variable: every view below refers to it, and a reader inside a view runs
-- again at each reference. The seed is one draft row, so read_json still has the list's shape when no PR is open.
COPY (SELECT * FROM read_json(['skills/duckstack-review/queue_seed.json',
                               '/opt/homebrew/bin/gh pr list --repo asubbarao/duckstack --state open --author asubbarao --json id,number,title,body,headRefOid,isDraft,autoMergeRequest,statusCheckRollup |'],
                              union_by_name := true))
TO 'variable:open_prs.json' (FORMAT json);
-- review_due: rules passed and no review yet, or the review errored and its result file was removed (a re-run).
-- repo, review_dir and checkout (the checkout this tick runs in) are declared here once, as columns.
CREATE OR REPLACE VIEW open_prs AS
WITH listed AS (
    SELECT id AS pr_id, number AS pr_number, title, body, headRefOid AS head_sha, concat_ws('-', number, left(headRefOid, 12)) AS review_key,
           autoMergeRequest IS NOT NULL AS auto_merge,
           map_from_entries([{k: s.context, v: upper(s.state)} FOR s IN statusCheckRollup IF s.context IS NOT NULL]) AS statuses,
           statuses['duckstack/rules'] AS rules_state, statuses['duckstack/review'] AS review_state,
           '/Users/aloksubbarao/duckdb-skills' AS repo, '/Users/aloksubbarao/.duck/review' AS review_dir, getenv('PWD') AS checkout,
           concat(review_dir, '/results/', review_key, '.json') AS result_path   -- the head's review result, looked up once
    FROM read_json('variable:open_prs.json')
    WHERE NOT isDraft
)
SELECT *, path_exists(result_path) AS has_result,
       rules_state = 'SUCCESS' AND CASE review_state WHEN 'ERROR' THEN NOT has_result ELSE review_state IS NULL END AS review_due
FROM listed;
-- PRs with a step due this tick: rules not yet posted, or a review due. Only these are read.
CREATE OR REPLACE VIEW due_prs AS
SELECT * FROM open_prs WHERE list_contains([rules_state IS NULL, review_due], true);

-- What each PR changes since it left main: base = the newest commit of the PR's history that main also has.
CREATE OR REPLACE VIEW pr_changes AS
WITH main_history AS (
    SELECT main_log.commit_hash
    FROM (SELECT DISTINCT repo FROM due_prs) AS repos CROSS JOIN LATERAL git_log_each(repos.repo, 'origin/main') AS main_log
), pr_history AS (
    SELECT due_prs.pr_number, due_prs.repo, due_prs.head_sha, pr_log.commit_hash, pr_log.commit_date
    FROM due_prs CROSS JOIN LATERAL git_log_each(due_prs.repo, due_prs.head_sha) AS pr_log
), pr_bases AS (
    SELECT pr_number, repo, head_sha, arg_max(commit_hash, commit_date) AS base_sha
    FROM pr_history SEMI JOIN main_history USING (commit_hash) GROUP BY pr_number, repo, head_sha
)
SELECT pr_bases.pr_number, pr_bases.repo, pr_bases.head_sha, pr_bases.base_sha, changed.file_path, changed.status
FROM pr_bases CROSS JOIN LATERAL git_diff_tree_each(pr_bases.repo, pr_bases.base_sha, pr_bases.head_sha) AS changed;

-- Each changed file after the PR (side 'head') and, when modified, as it is on main (side 'base'), each read once.
CREATE OR REPLACE VIEW pr_versions AS
SELECT pr_changes.*, version.side, blob.text AS content
FROM pr_changes
CROSS JOIN UNNEST([{'side': 'head', 'sha': pr_changes.head_sha, 'wanted': pr_changes.status <> 'deleted'},
                   {'side': 'base', 'sha': pr_changes.base_sha, 'wanted': pr_changes.status = 'modified'}]) AS v(version)
CROSS JOIN LATERAL git_read_each(git_uri(pr_changes.repo, pr_changes.file_path, version.sha)) AS blob
WHERE version.wanted AND blob.is_text;
CREATE OR REPLACE VIEW pr_files AS
SELECT * EXCLUDE (side) FROM pr_versions WHERE side = 'head';

.read skills/duckstack-review/gate.sql

-- The lines a PR adds: of a line's numbers in the new file, those past the old file's copies of it.
CREATE OR REPLACE VIEW pr_added_lines AS
WITH new_lines AS (
    SELECT pr_number, file_path, split.line, list(split.line_number ORDER BY split.line_number) AS line_numbers
    FROM pr_files CROSS JOIN UNNEST(string_split(content, E'\n')) WITH ORDINALITY AS split(line, line_number)
    GROUP BY ALL
), old_lines AS (
    SELECT pr_number, file_path, old.line, count(old.line) AS copies
    FROM pr_versions CROSS JOIN UNNEST(string_split(content, E'\n')) AS old(line)
    WHERE side = 'base' GROUP BY ALL
)
SELECT new_lines.pr_number, new_lines.file_path, added.line_number, new_lines.line
FROM new_lines LEFT JOIN old_lines USING (pr_number, file_path, line)
CROSS JOIN UNNEST(new_lines.line_numbers[coalesce(old_lines.copies, 0) + 1:]) AS added(line_number);

-- Each rule hit as one line of text, the same in the PR comment and in the reviewer's prompt.
CREATE OR REPLACE VIEW rule_hit_lines AS
SELECT pr_number, action, file_path,
       tera_render($t$- **{{ action }}** `{{ check_id }}` in {{ file_path }}: {{ message }}$t$, hit::JSON, autoescape := false) AS line
FROM pr_rule_hits AS hit;

-- One prompt per PR that passed the rules and has no review yet; the launch puts the rubric files in front of it.
CREATE OR REPLACE VIEW review_prompts AS
WITH added_by_file AS (
    SELECT pr_number, file_path, string_agg(concat_ws(': ', line_number, line), E'\n' ORDER BY line_number) AS added
    FROM pr_added_lines GROUP BY pr_number, file_path
), file_sections AS (   -- every changed file, deletions included, so a PR that only deletes still has a prompt
    SELECT pr_changes.pr_number, pr_changes.file_path,
           tera_render($t$## {{ file_path }} ({{ status }})

Lines this PR adds, as line: text
{{ added }}

The whole file after the PR
{{ content }}
$t$, json_object('file_path', pr_changes.file_path, 'status', pr_changes.status,
                 'added', coalesce(added_by_file.added, '(none)'), 'content', coalesce(pr_files.content, '(the file is deleted)')),
                       autoescape := false) AS section
    FROM pr_changes
    LEFT JOIN pr_files ON pr_files.pr_number = pr_changes.pr_number AND pr_files.file_path = pr_changes.file_path
    LEFT JOIN added_by_file ON added_by_file.pr_number = pr_changes.pr_number AND added_by_file.file_path = pr_changes.file_path
    WHERE pr_changes.file_path <> 'hooks/check_hits.sql'   -- generated from hook_checks.sql by render_hits.sql
), warnings AS (
    SELECT pr_number, string_agg(line, E'\n' ORDER BY file_path) AS warnings
    FROM rule_hit_lines WHERE action = 'warn' GROUP BY pr_number
)
SELECT open_prs.review_key,
       tera_render('review_prompt.tera',
                   json_object('number', open_prs.pr_number, 'title', open_prs.title, 'body', open_prs.body,
                               'warnings', coalesce(warnings.warnings, 'none'),
                               'files', string_agg(file_sections.section, E'\n' ORDER BY file_sections.file_path)),
                   autoescape := false, template_path := 'skills/duckstack-review/*.tera') AS prompt
FROM open_prs JOIN file_sections USING (pr_number) LEFT JOIN warnings USING (pr_number)
WHERE open_prs.review_due
GROUP BY open_prs.review_key, open_prs.pr_number, open_prs.title, open_prs.body, warnings.warnings;

-- One prompt file per PR, prompts/review_key=<pr>-<sha>/data_0.csv, written raw (no quoting, no header).
COPY (SELECT review_key, prompt FROM review_prompts)
TO '/Users/aloksubbarao/.duck/review/prompts'
(FORMAT csv, HEADER false, QUOTE '', ESCAPE '', DELIMITER E'\x1f', PARTITION_BY (review_key), OVERWRITE_OR_IGNORE true);

-- Finished reviews of pending PRs: one read per result file, self-dispatched. The verdict is claude's
-- structured_output (from --json-schema); a run without it leaves review NULL, which posts 'error' with its text.
CREATE OR REPLACE VIEW review_results AS
WITH result_files AS (
    SELECT review_key, result_path AS path FROM open_prs WHERE review_state = 'PENDING' AND has_result
), rendered AS (
    SELECT review_key, tera_render($t$SELECT * FROM read_json('{{ path }}')$t$, f::JSON, autoescape := false) AS sql
    FROM result_files AS f
), dispatched AS (
    SELECT array_agg({review_key: review_key, receipt: selfdispatch(sql)}) AS receipts FROM rendered
), receipt_rows AS (
    SELECT sent.review_key, sent.receipt.body, TRY_CAST(sent.receipt.body AS JSON[]) AS result_rows
    FROM dispatched CROSS JOIN UNNEST(receipts) AS each_receipt(sent)
)
SELECT review_key, result_row ->> 'result' AS result_text, result_row -> 'structured_output' AS review
FROM receipt_rows CROSS JOIN UNNEST(result_rows) AS each_row(result_row)
UNION ALL
-- A receipt that is not rows (dev's error) is its own row, so the PR gets 'error' with dev's text, not 'pending' forever.
SELECT review_key, body, NULL FROM receipt_rows WHERE result_rows IS NULL;

-- Every GitHub post this tick makes: statuses (descriptions as rows), comments, and auto-merge.
CREATE OR REPLACE VIEW github_posts AS
WITH status_text AS (
    SELECT unnest([
        {'context': 'duckstack/rules',  'state': 'failure', 'description': 'Blocking rule hits; see the PR comment'},
        {'context': 'duckstack/rules',  'state': 'success', 'description': 'No blocking rule hits'},
        {'context': 'duckstack/review', 'state': 'pending', 'description': 'Opus 5.5 is reviewing'},
        {'context': 'duckstack/review', 'state': 'success', 'description': 'Opus 5.5: clean'},
        {'context': 'duckstack/review', 'state': 'failure', 'description': 'Opus 5.5: changes needed; see the PR comment'},
        {'context': 'duckstack/review', 'state': 'error',   'description': 'No verdict; see the comment. Remove its result file to rerun'}
    ], recursive := true)
), rules_summary AS (   -- the only read of the rule hits in this view
    SELECT pr_number, bool_or(action = 'block') AS blocked, string_agg(line, E'\n' ORDER BY action, file_path) AS lines
    FROM rule_hit_lines GROUP BY pr_number
), reviews AS (         -- the only read of review_results in this view
    FROM review_results
), finding_lines AS (
    SELECT review_key, string_agg(tera_render($t$- `{{ file }}:{{ line }}` **{{ rule }}**: {{ problem }}
  Rewrite: {{ rewrite }}$t$, finding, autoescape := false), E'\n') AS lines
    FROM reviews CROSS JOIN UNNEST(TRY_CAST(review -> 'findings' AS JSON[])) AS each_finding(finding)
    GROUP BY review_key
), review_summary AS (
    SELECT reviews.review_key, reviews.review ->> 'verdict' AS verdict,
           -- no verdict came back: show what the reviewer wrote, so the error says why
           CASE WHEN reviews.review IS NULL
                THEN tera_render($t$The reviewer gave no verdict. Its answer, cut at 3000 characters:

{{ text }}$t$, json_object('text', left(reviews.result_text, 3000)), autoescape := false)
                ELSE finding_lines.lines END AS lines
    FROM reviews LEFT JOIN finding_lines USING (review_key)
), outcomes AS (        -- one row per PR and status to post this tick; lines and signature make its comment
    SELECT open_prs.pr_number, open_prs.head_sha, 'duckstack/rules' AS context,
           CASE WHEN rules_summary.blocked THEN 'failure' ELSE 'success' END AS state, rules_summary.lines,
           'duckstack review queue, rule gate (hooks/hook_checks.sql)' AS signature
    FROM open_prs LEFT JOIN rules_summary USING (pr_number) WHERE open_prs.rules_state IS NULL
    UNION ALL
    SELECT pr_number, head_sha, 'duckstack/review', 'pending', NULL, NULL FROM open_prs WHERE review_due
    UNION ALL
    SELECT open_prs.pr_number, open_prs.head_sha, 'duckstack/review',
           CASE review_summary.verdict WHEN 'clean' THEN 'success' WHEN 'changes' THEN 'failure' ELSE 'error' END,
           coalesce(review_summary.lines, 'No findings.'), 'Opus 5.5, duckstack review queue (duckstack-review skill)'
    FROM open_prs JOIN review_summary USING (review_key)
)
SELECT pr_number, concat('https://api.github.com/repos/asubbarao/duckstack/statuses/', head_sha) AS url,
       json_object('context', context, 'state', state, 'description', status_text.description) AS payload
FROM outcomes JOIN status_text USING (context, state)
UNION ALL
SELECT pr_number, concat('https://api.github.com/repos/asubbarao/duckstack/issues/', pr_number, '/comments'),
       json_object('body', tera_render($t$**{{ context }}: {{ state }}**

{{ lines }}

_{{ signature }}_$t$, outcome::JSON, autoescape := false))
FROM outcomes AS outcome WHERE lines IS NOT NULL
UNION ALL
SELECT pr_number, 'https://api.github.com/graphql',
       json_object('query', 'mutation($id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: MERGE}) { clientMutationId } }',
                   'variables', json_object('id', pr_id))
FROM open_prs WHERE NOT auto_merge;

-- The review's launch (review_launch.tera). The rubric comes from the checkout this tick runs in, so it matches this
-- queue.sql; the verdict schema and claude's settings are constants here, passed inline.
CREATE OR REPLACE VIEW review_launches AS
WITH launch_rows AS (
    SELECT pr_number, review_dir,
           [concat(checkout, '/skills/duckstack-review/SKILL.md'), concat(checkout, '/skills/self-dispatch/RULES.md'),
            concat(checkout, '/SQL-MANIFESTO.md')] AS rubric,
           concat('prompts/review_key=', review_key, '/data_0.csv') AS prompt,
           concat('results/', review_key, '.part') AS part, concat('results/', review_key, '.json') AS result,
           ['/Users/aloksubbarao/.local/bin/claude', '-p', '--model', 'claude-opus-5-5', '--tools=', '--output-format', 'json',
            '--no-session-persistence', '--strict-mcp-config', '--disable-slash-commands'] AS claude,
           {'disableAllHooks': true}::JSON::VARCHAR AS settings,
           {'type': 'object', 'required': ['verdict', 'findings'],
            'properties': {'verdict': {'type': 'string', 'enum': ['clean', 'changes']},
                           'findings': {'type': 'array', 'items': {'type': 'object', 'required': ['file', 'line', 'rule', 'problem', 'rewrite'],
                                        'properties': {'file': {'type': 'string'}, 'line': {'type': 'integer'}, 'rule': {'type': 'string'},
                                                       'problem': {'type': 'string'}, 'rewrite': {'type': 'string'}}}}}}::JSON::VARCHAR AS schema
    FROM open_prs WHERE review_due
)
SELECT pr_number,
       -- trim newlines too: shellfs runs a source as a command only when it ends with '|'
       trim(tera_render('review_launch.tera', launch::JSON, autoescape := false, template_path := 'skills/duckstack-review/*.tera'), E' \n') AS command
FROM launch_rows AS launch;

.output stdout
WITH posted AS (
    SELECT array_agg({pr_number: pr_number, url: url,
                      receipt: quackapi_post(url, payload::VARCHAR, 'application/json',
                                             MAP {'Authorization': concat('Bearer ', getenv('GH_TOKEN')),
                                                  'Accept': 'application/vnd.github+json', 'User-Agent': 'duckstack-review-queue'})}) AS receipts
    FROM github_posts
), rendered AS (
    SELECT pr_number, tera_render('shell.tera', json_object('reader', 'read_text', 'sources', [command], 'options', ''),
                                  autoescape := false, template_path := 'skills/self-dispatch/templates/*.tera') AS sql
    FROM review_launches
), dispatched AS (
    SELECT array_agg({pr_number: pr_number, url: 'review launch', receipt: selfdispatch(sql)}) AS receipts FROM rendered
)
SELECT now() AS ticked_at, sent.pr_number, sent.url, sent.receipt.status, left(sent.receipt.body, 160) AS body
FROM posted CROSS JOIN UNNEST(receipts) AS each_receipt(sent)
UNION ALL
SELECT now(), sent.pr_number, sent.url, sent.receipt.status, left(sent.receipt.body, 160)
FROM dispatched CROSS JOIN UNNEST(receipts) AS each_receipt(sent);

-- The review queue's program for one PR: what it changes, and the hook's own checks on it. queue.sql dispatches it
-- once per PR with a step due, as its own `duckdb :memory: -f` run from a checkout root (the queue's is ~/.duck/deploy,
-- the checkout of main, so the rules are the merged ones), with the PR in PR_REPO, PR_NUMBER, PR_BASE and PR_HEAD.
-- Its views (the hook's src, n, tc_src, toolcall_facts, ...) live and die in that process. It prints one JSON row.
-- Every .sql file the PR changes, and every ```sql block in a .md it changes, goes through toolcall_facts and
-- hook_checks as if an agent had just written it, so a PR is held to the same rules as a tool call.
.output /dev/null
LOAD duck_tails;
LOAD scalarfs;
LOAD shellfs;
LOAD sitting_duck;
LOAD markdown;
LOAD tera;
CREATE OR REPLACE VIEW pr_changes AS
SELECT file_path, status FROM git_diff_tree(getenv('PR_REPO'), getenv('PR_BASE'), getenv('PR_HEAD'));
-- Each changed file after the PR (side 'head') and, when modified, as it is on main (side 'base'): one git_read per
-- file and side, self-dispatched; the row's keys ride the GROUP BY.
CREATE OR REPLACE VIEW pr_versions AS
WITH wanted AS (
    SELECT pr_changes.*, version.side, quote_literal(git_uri(getenv('PR_REPO'), pr_changes.file_path, version.sha)) AS uri_literal
    FROM pr_changes
    CROSS JOIN UNNEST([{'side': 'head', 'sha': getenv('PR_HEAD'), 'wanted': pr_changes.status <> 'deleted'},
                       {'side': 'base', 'sha': getenv('PR_BASE'), 'wanted': pr_changes.status = 'modified'}]) AS v(version)
    WHERE version.wanted
), read_dispatch AS (
    SELECT file_path, status, side, array_agg(selfdispatch(tera_render($t$
        SELECT is_text, text FROM git_read({{ uri_literal }})
    $t$, wanted::JSON, autoescape := false))) AS receipts
    FROM wanted GROUP BY ALL
), blobs AS (          -- a read that failed keeps its row, with dev's answer as read_error, so the PR is blocked
    SELECT file_path, status, side, (e.row->>'is_text')::BOOLEAN AS is_text, e.row->>'text' AS content,
           CASE WHEN e.row IS NULL THEN coalesce(left(receipt.body, 300), receipt.error) END AS read_error
    FROM read_dispatch CROSS JOIN UNNEST(receipts) AS r(receipt)
    -- a file that exists reads as one row, so no rows is a failure too
    CROSS JOIN UNNEST(coalesce(nullif(TRY_CAST(receipt.body AS JSON[]), []), [NULL::JSON])) AS e(row)
)
SELECT file_path, status, side, content, read_error FROM blobs WHERE is_text IS NOT false;

-- A ```sql block whose first line is '-- BAD' is a deliberate counter-example: its hits are reported as 'example'.
CREATE OR REPLACE VIEW pr_sql AS
SELECT file_path, side, content, false AS bad_example FROM pr_versions WHERE ends_with(file_path, '.sql') AND read_error IS NULL
UNION ALL
-- named <file>#<n>.sql so toolcall_facts reads its extension as .sql
SELECT tera_render('{{ file_path }}#{{ ordinality }}.sql', {'file_path': file_path, 'ordinality': block.ordinality}::JSON,
                   autoescape := false) AS file_path, side, block.code_block.code AS content,
       starts_with(ltrim(block.code_block.code), '-- BAD') AS bad_example
FROM pr_versions CROSS JOIN UNNEST(md_extract_code_blocks(content)) WITH ORDINALITY AS block(code_block, ordinality)
WHERE ends_with(file_path, '.md') AND block.code_block.language = 'sql';
CREATE OR REPLACE VIEW tc_src AS
SELECT file_path, side, bad_example, concat_ws(':', side, file_path) AS call_id, 'pr' AS session, now() AS ts,
       false AS subagent, 'Write' AS tool_name,
       json_object('file_path', file_path, 'content', content)::VARCHAR AS input, NULL::BOOLEAN AS next_prompt_corrects
FROM pr_sql;
-- The hook's own parse-bash inputs; no Bash calls come from a PR, so they are empty.
.read hooks/bash_input.sql
.read hooks/parse_bash_view.sql
.read hooks/toolcall_facts.sql
.read hooks/hook_checks.sql
.read hooks/check_hits.sql
-- Each check that fired on the PR's version as one line of text, the same in the PR comment and in the reviewer's
-- prompt. Action 'block' fails the PR; 'warn', 'example', and 'existing' (the same check already fires on main's copy
-- of the file, so the PR did not add it) are reported with it.
-- shortcut: matched per file and check, so a second hit of a check the file already has passes; the Opus review
-- still sees the added lines. Match per line once check_hits carries line numbers.
CREATE OR REPLACE VIEW pr_rule_hits AS
WITH file_hits AS (
    SELECT DISTINCT tc_src.side, tc_src.file_path, tc_src.bad_example, check_hits.check_id
    FROM check_hits JOIN tc_src USING (call_id)
), hits AS (
    SELECT head.file_path, head.check_id, hook_checks.message,
           CASE WHEN head.bad_example THEN 'example' WHEN base.check_id IS NOT NULL THEN 'existing' ELSE hook_checks.action END AS action
    FROM file_hits AS head JOIN hook_checks USING (check_id)
    LEFT JOIN file_hits AS base ON base.side = 'base' AND (base.file_path, base.check_id) = (head.file_path, head.check_id)
    WHERE head.side = 'head' AND hook_checks.action IN ('block', 'warn')
)
SELECT file_path, action,
       tera_render($t$- **{{ action }}** `{{ check_id }}` in {{ file_path }}: {{ message }}$t$, hit::JSON, autoescape := false) AS line
FROM hits AS hit;

-- The PR as one row: whether it is blocked, and the rule lines for its comment.
CREATE OR REPLACE VIEW pr_review AS
WITH parts AS (
    SELECT file_path, action, line FROM pr_rule_hits
    UNION ALL
    SELECT file_path, 'block', tera_render($t$- **block** `read_failed` in {{ file_path }} ({{ side }}): {{ read_error }}$t$,
                                           failed::JSON, autoescape := false)
    FROM pr_versions AS failed WHERE read_error IS NOT NULL
)
SELECT getenv('PR_NUMBER')::INTEGER AS pr_number, getenv('PR_BASE') AS base_sha,
       coalesce(bool_or(action = 'block'), false) AS blocked,
       string_agg(line, E'\n' ORDER BY action, file_path, line) AS rule_lines
FROM parts;
.output stdout
.mode json
FROM pr_review;

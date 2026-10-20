-- duckstack review queue, one tick, one query. launchd (com.inframe.duckstack-review.plist, beside this file) runs it
-- every minute from ~/.duck/deploy, the checkout of main, with GH_TOKEN set to asubbarao's token.
-- Each open, non-draft PR by asubbarao on asubbarao/duckstack gets two statuses on its head commit, both required by
-- main's branch protection:
--   duckstack/rules   gate.sql: the hook's own checks on every changed .sql file and ```sql block;
--   duckstack/review  launch.sql: Opus 5.5 in the background; a later tick reads its result file and posts the verdict.
-- Stages, each one statement per row: listing (fetch, then every open PR with its statuses), programs (per PR with a
-- step due, gate.sql or launch.sql in its own duckdb process), resulting (per pending review with a result file, that
-- file); then statuses, comments and auto-merge are JSON posts to GitHub.
-- The state is the statuses on GitHub and the files in ~/.duck/review; a new push is a new head and is checked again.
WITH intent AS (
    SELECT getenv('HOME') AS home, concat(home, '/duckdb-skills') AS repo, getenv('PWD') AS checkout,
           concat(home, '/.duck/review/results') AS results_dir, 'asubbarao/duckstack' AS gh_repo,
           ['git', '-C', repo] AS git_in_repo,
           list_concat(git_in_repo, ['fetch', '-q', 'origin', '+refs/heads/main:refs/remotes/origin/main',
                                     quote_literal('+refs/pull/*/head:refs/remotes/origin/pr/*')]) AS fetch_cmd,
           ['/opt/homebrew/bin/gh', 'pr', 'list', '--repo', gh_repo, '--state', 'open', '--author', 'asubbarao', '--draft=false',
            '--json', 'number,id,headRefOid,autoMergeRequest,statusCheckRollup'] AS list_cmd,
           ['/opt/homebrew/bin/duckdb', ':memory:', '-json', '-f'] AS duckdb_file,
           'skills/duckstack-review/gate.sql' AS gate_program, 'skills/duckstack-review/launch.sql' AS launch_program,
           -- the reviewer: launch.sql runs $REVIEW_CLAUDE with these settings and verdict schema
           [concat(home, '/.local/bin/claude'), '-p', '--model', 'claude-opus-5-5', '--tools=', '--output-format', 'json',
            '--no-session-persistence', '--strict-mcp-config', '--disable-slash-commands'] AS claude_cmd,
           tera_render('{{ words | join(sep=" ") }}', {'words': claude_cmd}::JSON, autoescape := false) AS claude_line,
           {'disableAllHooks': true}::JSON::VARCHAR AS claude_settings,
           {'type': 'object', 'required': ['verdict', 'findings'],
            'properties': {'verdict': {'type': 'string', 'enum': ['clean', 'changes']},
                           'findings': {'type': 'array', 'items': {'type': 'object', 'required': ['file', 'line', 'rule', 'problem', 'rewrite'],
                                        'properties': {'file': {'type': 'string'}, 'line': {'type': 'integer'}, 'rule': {'type': 'string'},
                                                       'problem': {'type': 'string'}, 'rewrite': {'type': 'string'}}}}}}::JSON::VARCHAR AS review_schema,
           $t$SELECT * FROM read_json($src${{ fetch_cmd | join(sep=" ") }} && {{ list_cmd | join(sep=" ") }} |$src$)$t$ AS listing_template,
           -- the merge base is git's (duck_tails has none), taken by the program's own shell; env_words are sh-quoted
           $t$SELECT * FROM read_json($src$cd '{{ checkout }}' && PR_BASE=$({{ git_in_repo | join(sep=" ") }} merge-base origin/main {{ head_sha }}) {{ env_words | join(sep=" ") }} {{ duckdb_file | join(sep=" ") }} {{ program }} |$src$)$t$ AS program_template,
           $t$SELECT * FROM read_json('{{ result_path }}')$t$ AS result_template,
           MAP {'duckstack/rules': MAP {'failure': 'Blocking rule hits; see the PR comment', 'success': 'No blocking rule hits'},
                'duckstack/review': MAP {'pending': 'Opus 5.5 is reviewing', 'success': 'Opus 5.5: clean',
                                         'failure': 'Opus 5.5: changes needed; see the PR comment',
                                         'error': 'No verdict; see the comment. Remove its result file to rerun'}} AS status_texts,
           MAP {'duckstack/rules': 'duckstack review queue, rule gate (hooks/hook_checks.sql)',
                'duckstack/review': 'Opus 5.5, duckstack review queue (duckstack-review skill)'} AS signatures,
           'https://api.github.com/repos/{{ gh_repo }}/statuses/{{ head_sha }}' AS status_url,
           'https://api.github.com/repos/{{ gh_repo }}/issues/{{ pr_number }}/comments' AS comment_url,
           $t$**{{ context }}: {{ state }}**

{{ lines }}

_{{ signatures[context] }}_$t$ AS comment_template,
           'https://api.github.com/graphql' AS graphql_url,
           'mutation($id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: MERGE}) { clientMutationId } }' AS auto_merge_mutation,
           MAP {'Authorization': concat('Bearer ', getenv('GH_TOKEN')), 'Accept': 'application/vnd.github+json',
                'User-Agent': 'duckstack-review-queue'} AS github_headers
), listing AS (
    SELECT *, 'listing' AS stage,
           array_agg(selfdispatch(tera_render(listing_template, intent::JSON, autoescape := false))) AS receipts
    FROM intent GROUP BY ALL
), listed AS (         -- the rollup stays JSON: a PR with no checks yet has an empty one, which read_json leaves untyped
    SELECT listing.* EXCLUDE (receipts, stage), (pr ->> 'number')::INTEGER AS pr_number, pr ->> 'headRefOid' AS head_sha,
           pr ->> 'id' AS pr_id, (pr ->> 'autoMergeRequest') IS NOT NULL AS auto_merge,
           map_from_entries([{k: s ->> 'context', v: upper(s ->> 'state')}
                             FOR s IN ((pr -> 'statusCheckRollup')::JSON[]) IF (s ->> 'context') IS NOT NULL]) AS statuses,
           statuses['duckstack/rules'] AS rules_state, statuses['duckstack/review'] AS review_state,
           concat(results_dir, '/', pr_number, '-', left(head_sha, 12), '.json') AS result_path
    FROM listing CROSS JOIN UNNEST(receipts) AS t(receipt) CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(pr)
), planned AS (        -- the step each PR has due, and the env its program runs with
    SELECT *, path_exists(result_path) AS has_result,
           -- a review is due once the rules pass, and again when an errored review's result file is removed
           rules_state = 'SUCCESS' AND CASE review_state WHEN 'ERROR' THEN NOT has_result ELSE review_state IS NULL END AS review_due,
           CASE WHEN review_due THEN launch_program WHEN rules_state IS NULL THEN gate_program END AS program,
           CASE WHEN review_due THEN 'duckstack/review' ELSE 'duckstack/rules' END AS program_status,
           review_state = 'PENDING' AND has_result AS result_due,
           MAP {'PR_REPO': repo, 'PR_GH_REPO': gh_repo, 'PR_NUMBER': pr_number::VARCHAR, 'PR_HEAD': head_sha,
                'REVIEW_RESULT': result_path, 'REVIEW_CLAUDE': claude_line, 'REVIEW_SETTINGS': claude_settings,
                'REVIEW_SCHEMA': review_schema} AS program_env,
           -- NAME='value' for sh: a ' inside the value closes, escapes and reopens the quote
           list_transform(map_entries(program_env),
                          lambda env: concat(env.key, $q$='$q$, replace(env.value, $q$'$q$, $q$'\''$q$), $q$'$q$)) AS env_words
    FROM listed
), programs AS (
    SELECT *, 'programs' AS stage,
           array_agg(selfdispatch(tera_render(program_template, planned::JSON, autoescape := false))) AS receipts
    FROM planned WHERE program IS NOT NULL GROUP BY ALL
), gated AS (          -- gate.sql's verdict for the PR; a failed program prints no row and posts nothing
    SELECT programs.* EXCLUDE (receipts, stage), (gate_row ->> 'blocked')::BOOLEAN AS blocked, gate_row ->> 'rule_lines' AS rule_lines
    FROM programs CROSS JOIN UNNEST(receipts) AS t(receipt) CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(gate_row)
), resulting AS (
    SELECT *, 'resulting' AS stage,
           array_agg(selfdispatch(tera_render(result_template, planned::JSON, autoescape := false))) AS receipts
    FROM planned WHERE result_due GROUP BY ALL
), reviews AS (        -- the verdict is claude's structured_output; dev's error reading the file (its text) is the answer
    SELECT resulting.* EXCLUDE (receipts, stage), result_row -> 'structured_output' AS review, left(result_row ->> 'result', 3000) AS answer
    FROM resulting CROSS JOIN UNNEST(receipts) AS t(receipt)
    CROSS JOIN UNNEST(coalesce(TRY_CAST(receipt.body AS JSON[]), [json_object('result', receipt.body)])) AS e(result_row)
    -- a read that never reached dev (status 0, empty body) posts nothing; the next tick reads the file again
    WHERE receipt.status > 0 AND length(receipt.body) > 0
), finding_lines AS (
    SELECT pr_number, string_agg(tera_render($t$- `{{ file }}:{{ line }}` **{{ rule }}**: {{ problem }}
  Rewrite: {{ rewrite }}$t$, finding, autoescape := false), E'\n') AS lines
    FROM reviews CROSS JOIN UNNEST(TRY_CAST(review -> 'findings' AS JSON[])) AS f(finding)
    GROUP BY pr_number
), outcomes AS (       -- one row per PR and status to post this tick; a row with lines also gets a comment
    SELECT *, program_status AS context,
           CASE WHEN program_status = 'duckstack/review' THEN 'pending' WHEN blocked THEN 'failure' ELSE 'success' END AS state,
           CASE WHEN program_status = 'duckstack/rules' THEN rule_lines END AS lines
    FROM gated
    UNION ALL BY NAME
    SELECT reviews.*, 'duckstack/review' AS context,
           CASE review ->> 'verdict' WHEN 'clean' THEN 'success' WHEN 'changes' THEN 'failure' ELSE 'error' END AS state,
           -- no verdict came back: show what the reviewer wrote, so the error says why
           CASE WHEN review IS NULL THEN tera_render($t$The reviewer gave no verdict. Its answer, cut at 3000 characters:

{{ answer }}$t$, reviews::JSON, autoescape := false)
                ELSE coalesce(finding_lines.lines, 'No findings.') END AS lines
    FROM reviews LEFT JOIN finding_lines USING (pr_number)
), github_posts AS (   -- statuses, comments, and auto-merge for each PR that lacks it
    SELECT pr_number, tera_render(status_url, outcome::JSON, autoescape := false) AS url,
           json_object('context', context, 'state', state, 'description', status_texts[context][state]) AS payload, github_headers
    FROM outcomes AS outcome
    UNION ALL
    SELECT pr_number, tera_render(comment_url, outcome::JSON, autoescape := false),
           json_object('body', tera_render(comment_template, outcome::JSON, autoescape := false)), github_headers
    FROM outcomes AS outcome WHERE lines IS NOT NULL
    UNION ALL
    SELECT pr_number, graphql_url, json_object('query', auto_merge_mutation, 'variables', json_object('id', pr_id)), github_headers
    FROM planned WHERE NOT auto_merge
), posting AS (
    SELECT pr_number, url, payload, 'posting' AS stage,
           array_agg(quackapi_post(url, payload::VARCHAR, 'application/json', github_headers)) AS receipts
    FROM github_posts GROUP BY ALL
), stage_receipts AS (   -- every dispatching stage's rows; each row's receipts stay beside it
    FROM listing UNION ALL BY NAME FROM programs UNION ALL BY NAME FROM resulting UNION ALL BY NAME FROM posting
)
SELECT now() AS ticked_at, stage, pr_number, receipt.status, coalesce(receipt.status NOT BETWEEN 200 AND 299, true) AS failed,
       left(receipt.body, 160) AS body
FROM stage_receipts CROSS JOIN UNNEST(receipts) AS t(receipt);

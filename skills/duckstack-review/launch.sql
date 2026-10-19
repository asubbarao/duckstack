-- The review of one PR, started in the background. queue.sql dispatches it in place of gate.sql when the PR's review
-- is due, with gate.sql's env plus PR_GH_REPO, REVIEW_RESULT (this head's result file) and the reviewer as
-- REVIEW_CLAUDE, REVIEW_SETTINGS and REVIEW_SCHEMA.
-- It prints gate.sql's row, then pipes one prompt into claude: the rubric files, then review_prompt.tera filled with the
-- PR's title, body, rule warnings and changed files. claude's JSON goes to <result>.part, renamed to the result file
-- when it ends; the verdict is its structured_output.
.read skills/duckstack-review/gate.sql
.output /dev/null
COPY (
    -- the rubric files in path order (the manifesto first), then the PR's own prompt; title and body come from gh
    -- here, not through the queue's shell, so free text is never quoted
    WITH prompt_parts AS (
        SELECT filename, content AS part
        FROM read_text(['SQL-MANIFESTO.md', 'skills/duckstack-review/SKILL.md', 'skills/self-dispatch/RULES.md'])
        UNION ALL BY NAME
        SELECT tera_render('review_prompt.tera', pr_prompt::JSON, autoescape := false, template_path := 'skills/duckstack-review/*.tera') AS part
        FROM (FROM pr_review JOIN read_json($cmd$/opt/homebrew/bin/gh pr view "$PR_NUMBER" --repo "$PR_GH_REPO" --json number,title,body |$cmd$) AS pr_view
                   ON pr_view.number = pr_review.pr_number) AS pr_prompt
    )
    SELECT string_agg(part, '' ORDER BY filename NULLS LAST) AS prompt FROM prompt_parts
-- 0<&0 keeps the pipe as the background job's stdin; sh gives a background job /dev/null otherwise.
-- shortcut: $REVIEW_CLAUDE is split on spaces, so its words (claude's path under HOME and its flags) hold none.
) TO $cmd$| (cd "$HOME/.duck/review" && mkdir -p results && $REVIEW_CLAUDE --settings "$REVIEW_SETTINGS" --json-schema "$REVIEW_SCHEMA" > "$REVIEW_RESULT.part" 2>&1; mv "$REVIEW_RESULT.part" "$REVIEW_RESULT") 0<&0 > /dev/null 2>&1 &$cmd$
(FORMAT csv, HEADER false, QUOTE '', ESCAPE '', DELIMITER E'\x1f');

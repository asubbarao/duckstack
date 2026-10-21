-- The review of one PR, started in the background. queue.sql dispatches it in place of gate.sql when the PR's review
-- is due, with gate.sql's env plus PR_GH, PR_GH_REPO, REVIEW_RESULT (this head's result file) and the reviewer as
-- REVIEW_CLAUDE, REVIEW_SETTINGS and REVIEW_SCHEMA.
-- It prints gate.sql's row, then pipes one prompt into claude: the rubric files, then review_prompt.tera filled with the
-- PR's title, body, rule warnings and changed files. claude's JSON goes to <result>.part, renamed to the result file
-- when it ends; the verdict is its structured_output.
.read skills/duckstack-review/gate.sql
.output /dev/null
COPY (
    WITH rubric AS (      -- the rubric in the order the reviewer reads it: the manifesto, the skill, Alok's rules
        SELECT rubric_file.file_path, rubric_file.rubric_order,
               quote_literal(concat_ws('/', getenv('PWD'), rubric_file.file_path)) AS path_literal
        FROM UNNEST(['SQL-MANIFESTO.md', 'skills/duckstack-review/SKILL.md', 'skills/self-dispatch/RULES.md'])
             WITH ORDINALITY AS rubric_file(file_path, rubric_order)
    ), rubric_reads AS (  -- one read per file; the file's row keeps its order
        SELECT rubric_order, array_agg(selfdispatch(tera_render($t$SELECT content FROM read_text({{ path_literal }})$t$,
                                                                rubric::JSON, autoescape := false))) AS receipts
        FROM rubric GROUP BY ALL
    ), pr_view AS (       -- title and body come from gh here, not through the queue's shell, so free text is never quoted
        FROM read_json($cmd$"$PR_GH" pr view "$PR_NUMBER" --repo "$PR_GH_REPO" --json number,title,body |$cmd$)
    ), versions AS (      -- the PR's file versions, read from dev once: DuckDB materializes a CTE referenced twice
        FROM pr_versions
    ), line_copies AS (   -- each line's copies in order; the PR adds the head's copies past the base's count
        SELECT file_path, side, split.line, split.line_number,
               row_number() OVER (PARTITION BY file_path, side, split.line ORDER BY split.line_number) AS copy
        FROM versions CROSS JOIN UNNEST(string_split(content, E'\n')) WITH ORDINALITY AS split(line, line_number)
    ), added_by_file AS (
        SELECT new.file_path, string_agg(concat_ws(': ', new.line_number, new.line), E'\n' ORDER BY new.line_number) AS added
        FROM line_copies AS new
        ANTI JOIN line_copies AS old ON old.side = 'base' AND (old.file_path, old.line, old.copy) = (new.file_path, new.line, new.copy)
        WHERE new.side = 'head' GROUP BY new.file_path
    ), section_rows AS (  -- every changed file, deletions included, so a PR that only deletes still has one
        SELECT pr_changes.file_path, pr_changes.status, coalesce(added_by_file.added, '(none)') AS added,
               coalesce(head.content, '(the file is deleted)') AS content
        FROM pr_changes LEFT JOIN added_by_file USING (file_path)
        LEFT JOIN versions AS head ON head.side = 'head' AND head.read_error IS NULL AND head.file_path = pr_changes.file_path
    ), pr_parts AS (      -- the gate's warnings and one section per changed file
        SELECT file_path, line AS warning FROM pr_rule_hits WHERE action = 'warn'
        UNION ALL BY NAME
        SELECT file_path, tera_render($t$## {{ file_path }} ({{ status }})

Lines this PR adds, as line: text
{{ added }}

The whole file after the PR
{{ content }}
$t$, section_row::JSON, autoescape := false) AS section
        FROM section_rows AS section_row
    ), pr_texts AS (
        SELECT getenv('PR_NUMBER')::INTEGER AS pr_number, coalesce(string_agg(warning, E'\n' ORDER BY file_path, warning), 'none') AS warnings,
               string_agg(section, E'\n' ORDER BY file_path) AS files
        FROM pr_parts
    ), pr_prompt AS (
        FROM pr_texts JOIN pr_view ON pr_view.number = pr_texts.pr_number
    ), prompt_parts AS (  -- the rubric in its declared order, then the PR's own prompt
        SELECT rubric_order, file_row ->> 'content' AS part
        FROM rubric_reads CROSS JOIN UNNEST(receipts) AS t(receipt) CROSS JOIN UNNEST(TRY_CAST(receipt.body AS JSON[])) AS e(file_row)
        UNION ALL BY NAME
        SELECT tera_render('review_prompt.tera', pr_prompt::JSON, autoescape := false, template_path := 'skills/duckstack-review/*.tera') AS part
        FROM pr_prompt
    )
    SELECT string_agg(part, '' ORDER BY rubric_order NULLS LAST) AS prompt FROM prompt_parts
-- 0<&0 keeps the pipe as the background job's stdin; sh gives a background job /dev/null otherwise.
-- shortcut: $REVIEW_CLAUDE is split on spaces, so its words (claude's path under HOME and its flags) hold none.
) TO $cmd$| (cd "$HOME/.duck/review" && mkdir -p results && $REVIEW_CLAUDE --settings "$REVIEW_SETTINGS" --json-schema "$REVIEW_SCHEMA" > "$REVIEW_RESULT.part" 2>&1; mv "$REVIEW_RESULT.part" "$REVIEW_RESULT") 0<&0 > /dev/null 2>&1 &$cmd$
(FORMAT csv, HEADER false, QUOTE '', ESCAPE '', DELIMITER E'\x1f');

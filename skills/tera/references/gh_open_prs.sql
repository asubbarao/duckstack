-- Open PRs authored by each account, newest first, every gh search field plus the account.
-- --limit caps acquisition (gh defaults to 30; GitHub search stops at 1,000 matches); preview_limit caps the rows
-- each statement returns. Visibility is the active gh auth on dev.
-- Verified on dev 2026-10-17: two 200 receipts, one per account.
WITH accounts AS (
    SELECT unnest(['asubbarao', 'asubbarao-ifr']) AS account,
           'assignees,author,authorAssociation,body,closedAt,commentsCount,createdAt,id,isDraft,isLocked,isPullRequest,labels,number,repository,state,title,updatedAt,url' AS fields,
           4 AS preview_limit
), rendered AS (
    SELECT tera_render($t$
        SELECT '{{ account }}' AS account, *
        FROM read_json($cmd$gh search prs --author {{ account }} --state open --sort updated --order desc --limit 1000 --json {{ fields }} |$cmd$)
        ORDER BY updatedAt DESC
        LIMIT {{ preview_limit }}
    $t$, a::JSON, autoescape := false) AS sql
    FROM accounts AS a
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);

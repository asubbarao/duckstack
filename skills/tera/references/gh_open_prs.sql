-- Proven interactively before saving. All 18 gh search PR fields, plus account.
-- --limit controls acquisition (gh defaults to 30); SQL LIMIT controls displayed rows.
-- Acquisition sorts by updated time so its cap preserves recency. GitHub search is capped
-- at 1,000 matches per search; this is not an unlimited census. Visibility uses active gh auth.
-- Flags are shell fragments; options are SQL fragments. Neither is automatic escaping.
WITH rendered AS (
  SELECT tera_render('gh_open_prs.tera', json_object('accounts',['asubbarao','asubbarao-ifr'], 'flags',[{'name':'--state','value':'open'},{'name':'--sort','value':'updated'},{'name':'--order','value':'desc'},{'name':'--limit','value':'1000'},{'name':'--json','value':'assignees,author,authorAssociation,body,closedAt,commentsCount,createdAt,id,isDraft,isLocked,isPullRequest,labels,number,repository,state,title,updatedAt,url'}], 'options',[{'name':'maximum_depth','value':'-1'}], 'preview_limit',4),
    autoescape := false,
    template_path := '/Users/aloksubbarao/duckdb-skills/skills/tera/references/*.tera'
  ) AS statement
)
, posted AS (
  SELECT statement,
         from_json(http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', statement)),
                   '{"status": "INTEGER", "body": "VARCHAR"}') AS receipt
  FROM rendered
)
SELECT statement, receipt.status, receipt.body FROM posted;

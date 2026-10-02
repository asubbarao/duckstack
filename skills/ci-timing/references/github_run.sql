-- One live GitHub run, with every API field and nested value retained.
-- Requires gh on PATH, authenticated for CI_REPO; set CI_REPO and CI_RUN_ID.
INSTALL shellfs FROM community;
LOAD shellfs;

WITH run AS (
    SELECT *
    FROM read_json($cmd$gh api "repos/${CI_REPO:?set CI_REPO}/actions/runs/${CI_RUN_ID:?set CI_RUN_ID}" |$cmd$)
)
SELECT * FROM run
WHERE CASE WHEN id > 0 THEN true ELSE error('GitHub response has no run identity') END;

-- One row per API page in the run's latest attempt; jobs and steps remain nested.
-- Requires authenticated gh, CI_REPO and CI_RUN_ID. --paginate includes every page.
INSTALL shellfs FROM community;
LOAD shellfs;

SELECT *
FROM read_json($cmd$gh api "repos/${CI_REPO:?set CI_REPO}/actions/runs/${CI_RUN_ID:?set CI_RUN_ID}/jobs?per_page=100" --paginate --slurp |$cmd$);

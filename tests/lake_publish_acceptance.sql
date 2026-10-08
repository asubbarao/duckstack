-- Run on selected dev after a synthetic successful publish, a recovery rerun,
-- and a synthetic pre-existing conflicting remote object. No writes here.
WITH evidence AS (
 SELECT *, from_json(receipt,
   '{"result":{"outcome":"VARCHAR","reason":"VARCHAR","version_id":"VARCHAR","manifest_version_id":"VARCHAR","copied":"BOOLEAN"}}').result AS result
 FROM agents.lake_outbox WHERE source_ref = 'synthetic:publisher-contract'
), checks AS (
 SELECT len(list(publication_id) FILTER (
   WHERE status='published' AND result.outcome='published' AND result.copied=false
     AND len(result.version_id)>0 AND len(result.manifest_version_id)>0)) AS recovered,
   len(list(publication_id) FILTER (
   WHERE status='conflict' AND result.outcome='conflict' AND result.reason='remote_content_conflict'
     AND result.copied=false)) AS conflicts
 FROM evidence
)
SELECT CASE WHEN recovered >= 1 AND conflicts >= 1 THEN true
            ELSE error('Missing no-op recovery or conflict-no-overwrite evidence') END AS publisher_contract
FROM checks;

-- Only one successful SQL result with an exact outcome is actionable. Error
-- text, multiple rows, and malformed HTTP bodies never become ready/registered.
WITH fixtures AS (
  SELECT 'single_ready' AS name, 200 AS executor_status, '[{"outcome":"ready"}]'::JSON AS raw_response
  UNION ALL SELECT 'single_registered', 200, '[{"outcome":"registered"}]'::JSON
  UNION ALL SELECT 'embedded_error_text', 200, '[{"error":"ready registered"}]'::JSON
  UNION ALL SELECT 'multiple_rows', 200, '[{"outcome":"ready"},{"outcome":"registered"}]'::JSON
  UNION ALL SELECT 'http_failure', 500, '[{"outcome":"registered"}]'::JSON
), parsed AS (
  SELECT *, try_cast(from_json(raw_response, '"VARCHAR"') AS STRUCT(outcome VARCHAR)[]) AS outcomes
  FROM fixtures
), classified AS (
  SELECT name, CASE WHEN executor_status=200 AND len(outcomes)=1
                         THEN list_extract(outcomes,1).outcome END AS outcome
  FROM parsed
), assertions AS (
  SELECT CASE WHEN count(name) FILTER (WHERE name='single_ready' AND outcome='ready')=1
                    AND count(name) FILTER (WHERE name='single_registered' AND outcome='registered')=1
                    AND count(name) FILTER (WHERE name NOT IN ('single_ready','single_registered') AND outcome IS NOT NULL)=0
              THEN 'catalog response parsing passed'
              ELSE error('catalog response parser accepted a non-actionable response') END AS test_result
  FROM classified
)
SELECT * FROM assertions;

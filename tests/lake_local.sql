-- Acceptance assertions for the local lake MCP tools.
-- Configure producer='alok' in agents.lake_config (or set DUCKSTACK_PRODUCER_ID)
-- before installing the tool. First call lake_record twice with these arguments:
--   kind          = test_result
--   source_ref    = lake_local_acceptance_v1
--   repo_revision = synthetic-v1
--   payload       = {"fixture":"lake-local-v1","value":"approved synthetic evidence"}
-- The two calls must return the same publication_id. Then run this SQL on the selected
-- dev service. It dispatches one literal-URI read per matching outbox row because
-- read_parquet/read_blob do not accept path columns as table-function arguments.

SELECT CASE WHEN len(list(publication_id))=1 THEN true
            ELSE error('lake_local acceptance: expected exactly one stable outbox row') END AS fixture_exists
FROM agents.lake_outbox
WHERE kind='test_result' AND source_ref='lake_local_acceptance_v1' AND repo_revision='synthetic-v1';

WITH fixture AS (
  SELECT publication_id, local_uri, sha256, byte_size
  FROM agents.lake_outbox
  WHERE kind = 'test_result'
    AND source_ref = 'lake_local_acceptance_v1'
    AND repo_revision = 'synthetic-v1'
),
fixture_gate AS (
  SELECT array_agg(publication_id ORDER BY publication_id) AS publication_ids
  FROM fixture
),
assertions AS (
  SELECT CASE
           WHEN len(publication_ids) IS DISTINCT FROM 1
             THEN error('lake_local acceptance: expected exactly one stable outbox row')
           ELSE true
         END AS valid, unnest(publication_ids) AS publication_id
  FROM fixture_gate
),
statements AS (
  SELECT f.publication_id,
         printf($q$
           SELECT CASE
                    WHEN p.publication_id != '%s'
                      THEN error('lake_local acceptance: object id mismatch')
                    WHEN p.payload_text != '{"fixture":"lake-local-v1","value":"approved synthetic evidence"}'
                      THEN error('lake_local acceptance: payload mismatch')
                    WHEN sha256(b.content) != '%s'
                      THEN error('lake_local acceptance: object SHA256 mismatch')
                    WHEN b.size::UBIGINT != %s
                      THEN error('lake_local acceptance: object byte size mismatch')
                    ELSE 'pass'
                  END AS result,
                  b.filename AS object_uri,
                  b.size AS byte_size,
                  sha256(b.content) AS sha256
           FROM read_parquet('%s') p, read_blob('%s') b
         $q$,
           replace(f.publication_id, '''', ''''''),
           replace(f.sha256, '''', ''''''),
           f.byte_size::VARCHAR,
           replace(f.local_uri, '''', ''''''),
           replace(f.local_uri, '''', '''''')) AS statement
  FROM fixture f
  JOIN assertions a USING (publication_id)
),
fired AS (
  SELECT publication_id, statement,
         http_post_form('http://localhost:9495/sql', MAP {}, MAP {'sql': statement}) AS response
  FROM statements
)
SELECT publication_id, statement,
       CASE WHEN response.status::INTEGER=200
                  AND len(from_json(from_json(response.body, '"VARCHAR"'), '[{"result":"VARCHAR"}]'))=1
                  AND list_contains(list_transform(from_json(from_json(response.body, '"VARCHAR"'), '[{"result":"VARCHAR"}]'), x -> x.result), 'pass')
            THEN from_json(response.body, '"VARCHAR"')
            ELSE error(response::VARCHAR) END AS assertion_result
FROM fired;

-- Negative checks are MCP calls, not SQL writes. Call lake_record with kind=conversation
-- and then with kind=test_result plus a synthetic payload containing "token=example";
-- both calls must fail before creating an agents.lake_outbox row or local object.

-- False-first guard: local retention and collective publication are separate.
WITH sources AS (
  SELECT filename, content FROM read_text(['server/lake_local.sql','server/lake_publish.sql'])
), checks AS (
  SELECT 'new records remain local' AS check_name,
         contains(content, 'share_requested BOOLEAN NOT NULL DEFAULT false') AS passed
  FROM sources WHERE ends_with(filename, 'lake_local.sql')
  UNION ALL
  SELECT 'one-id share tool',
         contains(content, 'WHERE publication_id=$publication_id::VARCHAR')
         AND contains(content, 'SET share_requested=true')
  FROM sources WHERE ends_with(filename, 'lake_local.sql')
  UNION ALL
  SELECT 'publisher gate',
         contains(content, 'AND share_requested')
         AND contains(content, 'bool_or(share_requested AND status')
  FROM sources WHERE ends_with(filename, 'lake_publish.sql')
)
SELECT check_name,
       CASE WHEN passed THEN 'pass'
            ELSE error('lake share contract failed: ' || check_name) END AS result
FROM checks ORDER BY check_name;

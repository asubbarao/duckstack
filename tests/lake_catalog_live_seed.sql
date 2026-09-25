-- Opt-in live seed. Run only after review, on the selected dev with local
-- MinIO already configured. It creates one unique synthetic local object and
-- a pending outbox row; the normal publisher and catalog schedule perform all
-- shared S3 and DuckLake work. It contains no credentials or customer content.
INSTALL scalarfs FROM community; LOAD scalarfs;
COPY (SELECT sha256('catalog-live-seed-' || uuid()::VARCHAR))
TO 'variable:lake_catalog_live_id' (FORMAT variable, LIST none);
COPY (
  SELECT getvariable('lake_catalog_live_id') AS publication_id,
         'catalogtest' AS producer, 'test_result' AS kind,
         'synthetic:catalog-live-seed' AS source_ref,
         'catalog-v1' AS repo_revision, now() AS created_at,
         's3://duckstack-local/shared/' || getvariable('lake_catalog_live_id') || '.parquet' AS local_uri,
         's3://inframe-duckstack-785081088852/raw/catalogtest/' || getvariable('lake_catalog_live_id') || '.parquet' AS remote_uri,
         'approved synthetic catalog registration evidence' AS payload_text
) TO ('s3://duckstack-local/shared/' || getvariable('lake_catalog_live_id') || '.parquet') (FORMAT parquet);

INSERT INTO agents.lake_outbox BY NAME
SELECT p.publication_id, p.producer, p.kind, p.source_ref, p.repo_revision,
       p.created_at, p.local_uri, p.remote_uri, sha256(b.content) AS sha256,
       b.size::UBIGINT AS byte_size, 'pending' AS status, 0 AS attempts,
       NULL::JSON AS receipt, NULL::VARCHAR AS last_error
FROM read_parquet('s3://duckstack-local/shared/' || getvariable('lake_catalog_live_id') || '.parquet') p,
     read_blob('s3://duckstack-local/shared/' || getvariable('lake_catalog_live_id') || '.parquet') b
ON CONFLICT (publication_id) DO NOTHING;

SELECT publication_id, producer, local_uri, remote_uri, sha256, byte_size, status
FROM agents.lake_outbox
WHERE publication_id=getvariable('lake_catalog_live_id');

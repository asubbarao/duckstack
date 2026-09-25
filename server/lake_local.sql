-- Local evidence lake tools for the selected dev DuckDB.
-- Run after shellfs, scalarfs, httpfs, http_client, quackapi and duckdb_mcp load,
-- and before mcp_server_start(). No source is read implicitly: lake_record accepts
-- only an explicitly supplied, approved text payload. Re-running is safe.

CREATE SCHEMA IF NOT EXISTS agents;

CREATE TABLE IF NOT EXISTS agents.lake_config (
  config_key VARCHAR PRIMARY KEY,
  config_value VARCHAR NOT NULL
);

INSERT INTO agents.lake_config BY NAME
SELECT 'producer' AS config_key, getenv('DUCKSTACK_PRODUCER_ID') AS config_value
WHERE nullif(getenv('DUCKSTACK_PRODUCER_ID'), '') IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM agents.lake_config WHERE config_key = 'producer');

CREATE TABLE IF NOT EXISTS agents.lake_allowed_kinds (
  kind VARCHAR PRIMARY KEY
);

INSERT INTO agents.lake_allowed_kinds BY NAME
SELECT 'artifact_metadata' AS kind
UNION ALL SELECT 'build_result'
UNION ALL SELECT 'decision'
UNION ALL SELECT 'human_note'
UNION ALL SELECT 'review_note'
UNION ALL SELECT 'source_excerpt'
UNION ALL SELECT 'test_result'
ON CONFLICT (kind) DO NOTHING;

CREATE TABLE IF NOT EXISTS agents.lake_outbox (
  publication_id VARCHAR PRIMARY KEY,
  producer VARCHAR NOT NULL,
  kind VARCHAR NOT NULL,
  source_ref VARCHAR NOT NULL,
  repo_revision VARCHAR,
  created_at TIMESTAMPTZ NOT NULL,
  local_uri VARCHAR NOT NULL,
  remote_uri VARCHAR NOT NULL,
  sha256 VARCHAR NOT NULL,
  byte_size UBIGINT NOT NULL,
  status VARCHAR NOT NULL DEFAULT 'pending',
  attempts INTEGER NOT NULL DEFAULT 0,
  receipt JSON,
  last_error VARCHAR,
  catalog_status VARCHAR,
  catalog_attempts INTEGER NOT NULL DEFAULT 0,
  catalog_lease UUID,
  catalog_started_at TIMESTAMPTZ,
  catalog_receipt JSON,
  catalog_error VARCHAR
);
ALTER TABLE agents.lake_outbox ADD COLUMN IF NOT EXISTS catalog_status VARCHAR;
ALTER TABLE agents.lake_outbox ADD COLUMN IF NOT EXISTS catalog_attempts INTEGER;
ALTER TABLE agents.lake_outbox ADD COLUMN IF NOT EXISTS catalog_lease UUID;
ALTER TABLE agents.lake_outbox ADD COLUMN IF NOT EXISTS catalog_started_at TIMESTAMPTZ;
ALTER TABLE agents.lake_outbox ADD COLUMN IF NOT EXISTS catalog_receipt JSON;
ALTER TABLE agents.lake_outbox ADD COLUMN IF NOT EXISTS catalog_error VARCHAR;
UPDATE agents.lake_outbox SET catalog_attempts=0 WHERE catalog_attempts IS NULL;

-- A primary-key claim serializes identical submissions. Claims stay durable after
-- interruption so a retry must reconcile an existing object, never blindly rewrite it.
CREATE TABLE IF NOT EXISTS agents.lake_record_claims (
  publication_id VARCHAR PRIMARY KEY,
  claim_token VARCHAR NOT NULL,
  claimed_at TIMESTAMPTZ NOT NULL DEFAULT current_timestamp
);

-- The MinIO root password is read into a connection-local ScalarFS variable and
-- immediately handed to DuckDB's scoped secret manager. The password is never
-- returned as a result, written to this file, or interpolated into a query literal.
COPY (
  SELECT password
  FROM read_csv(
    '/usr/bin/security find-generic-password -w -s duckstack-minio-root-password -a duckstack |',
    header := false,
    delim := chr(31),
    quote := '',
    columns := {'password': 'VARCHAR'})
) TO 'variable:duckstack_minio_password' (FORMAT variable, LIST none);

CREATE OR REPLACE SECRET minio_local (
  TYPE S3,
  KEY_ID 'duckstack',
  SECRET getvariable('duckstack_minio_password'),
  REGION 'us-east-1',
  ENDPOINT '127.0.0.1:9100',
  URL_STYLE 'path',
  USE_SSL false,
  SCOPE 's3://duckstack-local/');

PRAGMA mcp_publish_tool('lake_record',
  'Write explicitly supplied, approved evidence text (up to 4 KiB) to the local MinIO outbox and return its deterministic publication id plus SHA256 and byte size of the actual Parquet object. Allowed kinds only; raw conversations, queries and logs are not accepted by default.',
  $$
  WITH args AS (
    SELECT producer.config_value AS producer, $kind::VARCHAR AS kind, $source_ref::VARCHAR AS source_ref,
           nullif($repo_revision::VARCHAR, '') AS repo_revision, $payload::VARCHAR AS payload,
           uuid()::VARCHAR AS claim_token
    FROM (
      SELECT config_value FROM agents.lake_config WHERE config_key = 'producer'
      UNION ALL
      SELECT '' AS config_value WHERE NOT EXISTS (
        SELECT 1 FROM agents.lake_config WHERE config_key = 'producer')
    ) producer
  ),
  checked AS (
    SELECT *,
           CASE
             WHEN nullif(producer, '') IS NULL
               THEN error('lake_record: producer is not configured; set DUCKSTACK_PRODUCER_ID or agents.lake_config')
             WHEN translate(producer, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-', '') != ''
               THEN error('lake_record: producer may contain only letters, digits, underscore and hyphen')
             WHEN kind IS NULL THEN error('lake_record: kind is required')
             WHEN kind NOT IN (SELECT kind FROM agents.lake_allowed_kinds)
               THEN error('lake_record: kind is not allowlisted')
             WHEN nullif(source_ref, '') IS NULL
               THEN error('lake_record: source_ref is required')
             WHEN payload IS NULL
               THEN error('lake_record: payload is required')
             WHEN len(producer)>64 THEN error('lake_record: producer exceeds 64 characters')
             WHEN octet_length(encode(source_ref))>1024 THEN error('lake_record: source_ref exceeds 1 KiB')
             WHEN octet_length(encode(repo_revision))>256 THEN error('lake_record: repo_revision exceeds 256 bytes')
             WHEN octet_length(encode(payload)) > 4096
               THEN error('lake_record: payload exceeds the 4 KiB MCP transport limit')
             WHEN len(list_filter(
                    ['-----begin private key-----', 'begin rsa private key',
                     'begin openssh private key', 'aws_secret_access_key',
                     'secret_access_key', 'authorization: bearer ', 'password=',
                     'password:', 'passwd=', 'secret=', 'secret:', 'token=',
                     'token:', 'api_key=', 'api-key=', 'access_token=',
                     'client_secret=', 'ghp_', 'github_pat_', 'xoxb-', 'xoxp-',
                     'sk-ant-', 'sk-proj-', '"password"', '"token"', '"secret"', '"api_key"'],
                    marker -> position(marker IN lower(concat(payload, source_ref, repo_revision))) > 0)) > 0
               THEN error('lake_record: payload resembles a credential; nothing was written')
             ELSE true
           END AS accepted
    FROM args
  ),
  identified AS (
    SELECT *,
           sha256(json_object(
             'producer', producer,
             'kind', kind,
             'source_ref', source_ref,
             'repo_revision', repo_revision,
             'payload', payload)::VARCHAR) AS publication_id,
           's3://duckstack-local/shared/' || publication_id || '.parquet' AS local_uri,
           's3://inframe-duckstack-785081088852/raw/' || producer || '/' || publication_id || '.parquet' AS remote_uri
    FROM checked
    WHERE accepted
  ),
  preflight_statements AS (
    SELECT i.*,
      CASE WHEN existing.publication_id IS NOT NULL THEN
        printf($q$
          SELECT 'ALREADY_RECORDED' AS mode, publication_id, producer, kind,
                 source_ref, repo_revision, created_at, local_uri, remote_uri,
                 sha256, byte_size, status, attempts, receipt, last_error
          FROM agents.lake_outbox WHERE publication_id = '%s';
        $q$, replace(i.publication_id, '''', ''''''))
      ELSE
        printf($q$
          INSERT INTO agents.lake_record_claims BY NAME
          SELECT '%s' AS publication_id, '%s' AS claim_token ON CONFLICT (publication_id) DO NOTHING;
          SELECT CASE WHEN c.claim_token = '%s' THEN 'OWNED' ELSE 'BUSY' END AS claim_state,
                 paths.paths AS found_paths
          FROM agents.lake_record_claims c,
               (SELECT array_agg(file) AS paths FROM glob('%s*')) paths
          WHERE c.publication_id = '%s';
        $q$,
          replace(i.publication_id, '''', ''''''),
          replace(i.claim_token, '''', ''''''),
          replace(i.claim_token, '''', ''''''),
          replace(i.local_uri, '''', ''''''),
          replace(i.publication_id, '''', ''''''))
      END AS statement
    FROM identified i
    LEFT JOIN agents.lake_outbox existing USING (publication_id)
  ),
  preflight AS (
    SELECT p.*, http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql', statement)) AS response
    FROM preflight_statements p
  ),
  actions AS (
    SELECT *,
      CASE
        WHEN position('ALREADY_RECORDED' IN response.body) > 0 THEN NULL::VARCHAR
        WHEN response.status::INTEGER != 200 THEN printf('SELECT error(''lake_record: preflight failed with HTTP %s; no object write attempted'')', response.status::VARCHAR)
        WHEN position(local_uri IN response.body) > 0 THEN
          printf($q$
            SELECT CASE WHEN EXISTS (
              SELECT 1 FROM read_parquet('%s') p
              WHERE p.publication_id = '%s'
                AND p.producer = '%s'
                AND p.kind = '%s'
                AND p.source_ref = '%s'
                AND p.repo_revision IS NOT DISTINCT FROM %s
                AND sha256(json_object('producer', p.producer, 'kind', p.kind,
                     'source_ref', p.source_ref, 'repo_revision', p.repo_revision,
                     'payload', p.payload_text)::VARCHAR) = p.publication_id)
              THEN 'existing local object verified'
              ELSE error('lake_record: existing object does not match this submission; no rewrite attempted')
            END AS object_check;
            INSERT INTO agents.lake_outbox BY NAME
            SELECT p.publication_id, p.producer, p.kind, p.source_ref, p.repo_revision,
                   p.created_at, p.local_uri, p.remote_uri,
                   sha256(b.content) AS sha256, b.size::UBIGINT AS byte_size,
                   'pending' AS status, 0 AS attempts, NULL::JSON AS receipt,
                   NULL::VARCHAR AS last_error
            FROM read_parquet('%s') p, read_blob('%s') b
            WHERE p.publication_id = '%s'
              AND p.producer = '%s'
              AND p.kind = '%s'
              AND p.source_ref = '%s'
              AND p.repo_revision IS NOT DISTINCT FROM %s
              AND sha256(json_object('producer', p.producer, 'kind', p.kind,
                   'source_ref', p.source_ref, 'repo_revision', p.repo_revision,
                   'payload', p.payload_text)::VARCHAR) = p.publication_id
            ON CONFLICT (publication_id) DO NOTHING;
            SELECT publication_id, producer, kind, source_ref, repo_revision, created_at,
                   local_uri, remote_uri, sha256, byte_size, status, attempts, receipt, last_error
            FROM agents.lake_outbox WHERE publication_id = '%s';
          $q$,
            replace(local_uri, '''', ''''''), replace(publication_id, '''', ''''''),
            replace(producer, '''', ''''''), replace(kind, '''', ''''''),
            replace(source_ref, '''', ''''''),
            CASE WHEN repo_revision IS NULL THEN 'NULL::VARCHAR' ELSE chr(39) || replace(repo_revision, '''', '''''') || chr(39) END,
            replace(local_uri, '''', ''''''), replace(local_uri, '''', ''''''),
            replace(publication_id, '''', ''''''), replace(producer, '''', ''''''),
            replace(kind, '''', ''''''), replace(source_ref, '''', ''''''),
            CASE WHEN repo_revision IS NULL THEN 'NULL::VARCHAR' ELSE chr(39) || replace(repo_revision, '''', '''''') || chr(39) END,
            replace(publication_id, '''', ''''''))
        WHEN position('OWNED' IN response.body) > 0 THEN
          printf($q$
            COPY (SELECT '%s' AS publication_id, '%s' AS producer, '%s' AS kind,
                         '%s' AS source_ref, %s AS repo_revision,
                         current_timestamp AS created_at, '%s' AS local_uri,
                         '%s' AS remote_uri, '%s' AS payload_text)
            TO '%s' (FORMAT PARQUET);
            INSERT INTO agents.lake_outbox BY NAME
            SELECT p.publication_id, p.producer, p.kind, p.source_ref, p.repo_revision,
                   p.created_at, p.local_uri, p.remote_uri,
                   sha256(b.content) AS sha256, b.size::UBIGINT AS byte_size,
                   'pending' AS status, 0 AS attempts, NULL::JSON AS receipt,
                   NULL::VARCHAR AS last_error
            FROM read_parquet('%s') p, read_blob('%s') b
            ON CONFLICT (publication_id) DO NOTHING;
            SELECT publication_id, producer, kind, source_ref, repo_revision, created_at,
                   local_uri, remote_uri, sha256, byte_size, status, attempts, receipt, last_error
            FROM agents.lake_outbox WHERE publication_id = '%s';
          $q$,
            replace(publication_id, '''', ''''''), replace(producer, '''', ''''''),
            replace(kind, '''', ''''''), replace(source_ref, '''', ''''''),
            CASE WHEN repo_revision IS NULL THEN 'NULL::VARCHAR' ELSE chr(39) || replace(repo_revision, '''', '''''') || chr(39) END,
            replace(local_uri, '''', ''''''), replace(remote_uri, '''', ''''''),
            replace(payload, '''', ''''''), replace(local_uri, '''', ''''''),
            replace(local_uri, '''', ''''''), replace(local_uri, '''', ''''''),
            replace(publication_id, '''', ''''''))
        ELSE printf('SELECT error(''lake_record: another recorder owns this id, or a prior write is incomplete; inspect local_uri before retrying'')')
      END AS write_statement
    FROM preflight
  ),
  finished AS (
    SELECT response.status AS executor_status, response.body AS receipt_json
    FROM preflight WHERE position('ALREADY_RECORDED' IN response.body) > 0
    UNION ALL BY NAME
    SELECT response.status AS executor_status, response.body AS receipt_json
    FROM (SELECT http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql', write_statement)) AS response
          FROM actions WHERE write_statement IS NOT NULL) dispatched
  )
  SELECT * FROM finished
  $$,
  '{"kind":{"type":"string"},"source_ref":{"type":"string"},"repo_revision":{"type":"string","description":"Use an empty string when no repository revision applies."},"payload":{"type":"string","description":"Explicitly approved evidence text, at most 4 KiB. Common credential-shaped text is rejected."}}',
  '["kind","source_ref","repo_revision","payload"]', 'markdown');

PRAGMA mcp_publish_tool('lake_status',
  'List the latest 100 local outbox records with S3 publication and shared DuckLake catalog states, receipts, attempts, and errors.',
  'SELECT publication_id, producer, kind, source_ref, repo_revision, created_at, local_uri, remote_uri, sha256, byte_size, status, attempts, receipt, last_error, catalog_status, catalog_attempts, catalog_receipt, catalog_error FROM agents.lake_outbox ORDER BY created_at DESC LIMIT 100',
  '{}', '[]', 'markdown');

PRAGMA mcp_publish_tool('lake_search',
  'Search explicitly published evidence text in local MinIO. Searches at most the 100 newest local records; shared S3 search is a separate tool. Each result carries its local source URI and the inner read receipt or error.',
  $$
  WITH bounded AS (
    SELECT publication_id, status, local_uri AS source_uri
    FROM agents.lake_outbox
    ORDER BY created_at DESC
    LIMIT 100
  ),
  statements AS (
    SELECT *,
      printf(
        'SELECT * FROM read_parquet(''%s'') WHERE position(lower(''%s'') IN lower(payload_text)) > 0 LIMIT 5',
        replace(source_uri, '''', ''''''),
        replace($q::VARCHAR, '''', '''''')) AS statement
    FROM bounded
  ),
  fired AS (
    SELECT publication_id, status, source_uri, statement,
           http_post_form('http://localhost:9495/sql', MAP {}, MAP {'sql': statement}) AS response
    FROM statements
  )
  SELECT publication_id, status, source_uri, statement,
         response.status AS executor_status, response.body AS results_json
  FROM fired
  $$,
  '{"q":{"type":"string","description":"Literal case-insensitive substring to find in explicitly published payload text."}}',
  '["q"]', 'markdown');

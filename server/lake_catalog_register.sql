-- Register up to ten published local artifacts in the shared DuckLake catalog.
-- This is intended to be stored as agents.lake_programs.catalog_register and
-- run by the same two-minute schedule as the publisher. It never uploads data:
-- the publisher has already immutably created raw/<producer>/<publication>.parquet
-- and its manifest. An unavailable catalog leaves the local row retriable.
LOAD shellfs; LOAD http_client;
ALTER TABLE agents.lake_outbox ADD COLUMN IF NOT EXISTS catalog_status VARCHAR;
ALTER TABLE agents.lake_outbox ADD COLUMN IF NOT EXISTS catalog_attempts INTEGER;
ALTER TABLE agents.lake_outbox ADD COLUMN IF NOT EXISTS catalog_lease UUID;
ALTER TABLE agents.lake_outbox ADD COLUMN IF NOT EXISTS catalog_started_at TIMESTAMPTZ;
ALTER TABLE agents.lake_outbox ADD COLUMN IF NOT EXISTS catalog_receipt JSON;
ALTER TABLE agents.lake_outbox ADD COLUMN IF NOT EXISTS catalog_error VARCHAR;
UPDATE agents.lake_outbox SET catalog_attempts=0 WHERE catalog_attempts IS NULL;

-- Do this before claiming any row. The command always exits successfully so an
-- absent tunnel or expired AWS session yields one `offline` row rather than a
-- failed SQL request. Offline records therefore consume no catalog attempts.
CREATE TEMP TABLE lake_catalog_connectivity AS
FROM read_csv($cmd$/bin/sh -c 'if /usr/bin/nc -z 127.0.0.1 15439 >/dev/null 2>&1 && /opt/homebrew/bin/aws sts get-caller-identity --no-cli-pager >/dev/null 2>&1; then printf ready; else printf offline; fi' |$cmd$,
  header := false, delim := chr(31), quote := '', columns := {'state':'VARCHAR'},
  ignore_errors := false);
CREATE TEMP TABLE lake_catalog_gate AS
SELECT bool_or(state='ready') AS online FROM lake_catalog_connectivity;

-- The credentials/secret program is intentionally banked because it exceeds the
-- HTTP SQL-field limit. Offline runs send Quack a harmless SELECT, so the gate
-- is a no-op before any AWS CLI or Secrets Manager call.
LOAD quack; LOAD scalarfs;
COPY (
  SELECT CASE WHEN g.online THEN coalesce(p.sql, error('Missing catalog_credentials program'))
              ELSE 'SELECT ''offline'' AS outcome' END AS sql
  FROM lake_catalog_gate g
  LEFT JOIN agents.lake_programs p ON p.name='catalog_credentials'
) TO 'variable:lake_catalog_credentials_sql' (FORMAT variable, LIST none);
FROM quack_query('quack:localhost:9494', getvariable('lake_catalog_credentials_sql'),
                 token:=getenv('QUACK_TOKEN'));

CREATE TEMP TABLE lake_catalog_batch AS
SELECT * EXCLUDE(catalog_lease, catalog_started_at),
       uuid() AS catalog_lease, now() AS catalog_started_at
FROM agents.lake_outbox
WHERE status = 'published'
  AND CASE WHEN catalog_status IN ('registered', 'conflict') THEN false
           WHEN catalog_status = 'registering' AND catalog_started_at >= now() - INTERVAL '30 minutes' THEN false
           ELSE true END
  AND catalog_attempts < 5
  AND length(producer) BETWEEN 1 AND 64
  AND translate(producer, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-', '') = ''
  AND length(publication_id) = 64
  AND translate(publication_id, '0123456789abcdef', '') = ''
  AND remote_uri = printf('s3://inframe-duckstack-785081088852/raw/%s/%s.parquet', producer, publication_id)
  AND EXISTS (SELECT 1 FROM lake_catalog_gate WHERE online)
ORDER BY created_at, publication_id
LIMIT 10;

UPDATE agents.lake_outbox o
SET catalog_status = 'registering', catalog_attempts = o.catalog_attempts + 1,
    catalog_lease = b.catalog_lease, catalog_started_at = b.catalog_started_at,
    catalog_error = NULL
FROM lake_catalog_batch b
WHERE o.publication_id = b.publication_id
  AND o.status = 'published'
  AND o.catalog_attempts = b.catalog_attempts;

CREATE TEMP TABLE lake_catalog_preflight AS
WITH statements AS (
  SELECT b.publication_id, b.catalog_lease,
    printf($worker$
      LOAD ducklake;
      ATTACH IF NOT EXISTS 'ducklake:lake_catalog_ducklake' AS shared;
      WITH manifest AS (
        SELECT * FROM read_json('%s', columns={publication_id:'VARCHAR',producer:'VARCHAR',remote_uri:'VARCHAR',sha256:'VARCHAR',byte_size:'UBIGINT'})
      ), verified AS (
        SELECT CASE WHEN m.publication_id='%s' AND m.producer='%s' AND m.remote_uri='%s'
                           AND m.sha256='%s' AND m.byte_size=%s
                           AND sha256(b.content)=m.sha256 AND b.size=m.byte_size
                    THEN '%s' ELSE error('shared catalog manifest or Parquet integrity mismatch') END AS remote_uri
        FROM manifest m, read_blob('%s') b
      )
      SELECT CASE WHEN f.data_file IS NOT NULL THEN 'registered' ELSE 'ready' END AS outcome
      FROM verified v
      LEFT JOIN ducklake_list_files('shared', 'agent_evidence') f ON f.data_file=v.remote_uri;
    $worker$,
      replace('s3://inframe-duckstack-785081088852/manifests/' || b.producer || '/' || b.publication_id || '.json', chr(39), chr(39)||chr(39)),
      b.publication_id, b.producer, b.remote_uri, b.sha256, b.byte_size::VARCHAR,
      replace(b.remote_uri, chr(39), chr(39)||chr(39)), replace(b.remote_uri, chr(39), chr(39)||chr(39))
    ) AS statement
  FROM lake_catalog_batch b
), fired AS (
  SELECT publication_id, catalog_lease, statement,
         http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql',statement)) AS response
  FROM statements
), raw AS (
  SELECT publication_id, catalog_lease, response.status::INTEGER AS executor_status,
         response.body AS raw_response
  FROM fired
), parsed AS (
  SELECT *, try_cast(from_json(raw_response, '"VARCHAR"') AS STRUCT(outcome VARCHAR)[]) AS outcomes
  FROM raw
)
SELECT publication_id, catalog_lease, executor_status, raw_response,
       CASE WHEN executor_status=200 AND len(outcomes)=1 THEN list_extract(outcomes,1).outcome END AS outcome
FROM parsed;

UPDATE agents.lake_outbox o
SET catalog_status='registered',
    catalog_receipt=json_object('outcome','already_registered','raw_response',p.raw_response),
    catalog_error=NULL
FROM lake_catalog_preflight p
WHERE o.publication_id=p.publication_id AND o.catalog_lease=p.catalog_lease
  AND p.outcome='registered';

CREATE TEMP TABLE lake_catalog_commit AS
WITH ready AS (
  SELECT b.* FROM lake_catalog_batch b JOIN lake_catalog_preflight p USING(publication_id, catalog_lease)
  WHERE p.outcome='ready'
), statements AS (
  SELECT publication_id, catalog_lease,
    printf($worker$
      LOAD ducklake;
      ATTACH IF NOT EXISTS 'ducklake:lake_catalog_ducklake' AS shared;
      SELECT CASE WHEN EXISTS (SELECT 1 FROM ducklake_list_files('shared','agent_evidence') WHERE data_file='%s')
                  THEN error('shared catalog object was registered during this attempt') ELSE true END AS write_gate;
      CALL ducklake_add_data_files('shared','agent_evidence','%s');
      SELECT 'registered' AS outcome FROM ducklake_current_snapshot('shared');
    $worker$, replace(remote_uri,chr(39),chr(39)||chr(39)), replace(remote_uri,chr(39),chr(39)||chr(39))) AS statement
  FROM ready
), fired AS (
  SELECT publication_id, catalog_lease,
         http_post('http://localhost:9495/sql', MAP {'Content-Type':'application/json'}, json_object('sql',statement)) AS response
  FROM statements
), raw AS (
  SELECT publication_id, catalog_lease, response.status::INTEGER AS executor_status,
         response.body AS raw_response
  FROM fired
), parsed AS (
  SELECT *, try_cast(from_json(raw_response, '"VARCHAR"') AS STRUCT(outcome VARCHAR)[]) AS outcomes
  FROM raw
)
SELECT publication_id, catalog_lease, executor_status, raw_response,
       CASE WHEN executor_status=200 AND len(outcomes)=1 THEN list_extract(outcomes,1).outcome END AS outcome
FROM parsed;

UPDATE agents.lake_outbox o
SET catalog_status='registered',
    catalog_receipt=json_object('outcome','registered','raw_response',c.raw_response),
    catalog_error=NULL
FROM lake_catalog_commit c
WHERE o.publication_id=c.publication_id AND o.catalog_lease=c.catalog_lease
  AND c.outcome='registered';

UPDATE agents.lake_outbox o
SET catalog_status='failed', catalog_error='catalog_preflight_or_commit_failed',
    catalog_receipt=json_object('preflight_status',p.executor_status,'preflight_response',p.raw_response,
                                'commit_status',c.executor_status,'commit_response',c.raw_response)
FROM lake_catalog_batch b
LEFT JOIN lake_catalog_preflight p USING(publication_id,catalog_lease)
LEFT JOIN lake_catalog_commit c USING(publication_id,catalog_lease)
WHERE o.publication_id=b.publication_id AND o.catalog_lease=b.catalog_lease
  AND o.catalog_status='registering';

SELECT publication_id, catalog_status, catalog_attempts, catalog_receipt, catalog_error
FROM agents.lake_outbox
WHERE publication_id IN (SELECT publication_id FROM lake_catalog_batch)
ORDER BY publication_id;

-- Read-only adoption proof for the per-laptop MinIO ingress.
-- It deliberately does not create, restart, or reconfigure a container, bucket,
-- Keychain item, or DuckDB secret. Missing/mismatched state is returned as a
-- failed check so an operator can resolve it without overwriting existing state.
--
-- Invoke from a DuckDB process on the laptop that owns MinIO. Docker-compatible
-- CLI output is captured as data; no credential values are requested or emitted.

LOAD shellfs;

CREATE OR REPLACE TEMP TABLE lake_bootstrap_checks AS
WITH runtime AS (
  SELECT container_name
  FROM read_csv('docker ps --filter name=^duckstack-minio$ --format "{{.Names}}" |',
                header := false, columns := {'container_name':'VARCHAR'}, ignore_errors := true)
),
inspect AS (
  SELECT line AS inspect_json
  FROM read_csv('docker inspect --format "{{json .}}" duckstack-minio 2>/dev/null |',
                header := false, columns := {'line':'VARCHAR'}, ignore_errors := true)
),
repo_digests AS (
  SELECT line AS digest_json
  FROM read_csv('docker image inspect --format "{{json .RepoDigests}}" "$(docker inspect --format ''{{.Image}}'' duckstack-minio)" 2>/dev/null |',
                header := false, columns := {'line':'VARCHAR'}, ignore_errors := true)
),
health AS (
  SELECT line AS response
  FROM read_csv('curl --silent --output /dev/null --write-out "%{http_code}" http://127.0.0.1:9100/minio/health/live 2>/dev/null |',
                header := false, columns := {'line':'VARCHAR'}, ignore_errors := true)
),
decoded AS (
  SELECT try_cast(inspect_json AS JSON) AS container
  FROM inspect
),
fields AS (
  SELECT json_extract_string(container, '$.Name') AS container_name,
         json_extract_string(container, '$.Config.Image') AS configured_image,
         json_extract_string(container, '$.State.Status') AS state,
         json_extract_string(container, '$.HostConfig.PortBindings."9000/tcp"[0].HostIp') AS api_host,
         json_extract_string(container, '$.HostConfig.PortBindings."9000/tcp"[0].HostPort') AS api_port,
         json_extract_string(container, '$.HostConfig.PortBindings."9001/tcp"[0].HostPort') AS console_port,
         json_extract_string(container, '$.Mounts[0].Source') AS data_source,
         json_extract_string(container, '$.Mounts[0].Destination') AS data_target,
         json_extract_string(container, '$.Image') AS image_id
  FROM decoded
)
SELECT 'producer_id' AS check_name,
       nullif(getenv('DUCKSTACK_PRODUCER_ID'), '') IS NOT NULL AS passed,
       coalesce(nullif(getenv('DUCKSTACK_PRODUCER_ID'), ''), '<unset>') AS observed,
       'Set DUCKSTACK_PRODUCER_ID explicitly; never infer a device identity.' AS expected
UNION ALL
SELECT 'container_present', container_name IS NOT NULL,
       coalesce(container_name, '<missing>'), 'duckstack-minio'
FROM (SELECT (SELECT container_name FROM runtime) AS container_name) r
UNION ALL
SELECT 'container_running', state = 'running', coalesce(state, '<missing>'), 'running'
FROM (SELECT (SELECT state FROM fields) AS state) r
UNION ALL
SELECT 'loopback_api', api_host = '127.0.0.1' AND api_port = '9100',
       coalesce(api_host, '<missing>') || ':' || coalesce(api_port, '<missing>'), '127.0.0.1:9100'
FROM (SELECT (SELECT api_host FROM fields) AS api_host,
             (SELECT api_port FROM fields) AS api_port) r
UNION ALL
SELECT 'loopback_console', api_host = '127.0.0.1' AND console_port = '9101',
       coalesce(api_host, '<missing>') || ':' || coalesce(console_port, '<missing>'), '127.0.0.1:9101'
FROM (SELECT (SELECT api_host FROM fields) AS api_host,
             (SELECT console_port FROM fields) AS console_port) r
UNION ALL
SELECT 'data_mount', data_source = getenv('HOME') || '/.duck/minio/data' AND data_target = '/data',
       coalesce(data_source, '<missing>') || ' -> ' || coalesce(data_target, '<missing>'),
       getenv('HOME') || '/.duck/minio/data -> /data'
FROM (SELECT (SELECT data_source FROM fields) AS data_source,
             (SELECT data_target FROM fields) AS data_target) r
UNION ALL
SELECT 'image_pinned', configured_image IS NOT NULL AND image_id IS NOT NULL
         AND json_extract_string(try_cast((SELECT digest_json FROM repo_digests) AS JSON), '$[0]') IS NOT NULL,
       coalesce(configured_image, '<missing>') || ' @ ' || coalesce(image_id, '<missing>'),
       coalesce(json_extract_string(try_cast((SELECT digest_json FROM repo_digests) AS JSON), '$[0]'), '<missing RepoDigest>')
FROM (SELECT (SELECT configured_image FROM fields) AS configured_image,
             (SELECT image_id FROM fields) AS image_id) r
UNION ALL
SELECT 'api_health', coalesce(response = '200', false), coalesce(response, '<unavailable>'), '200'
FROM (SELECT (SELECT response FROM health) AS response) r;

SELECT * FROM lake_bootstrap_checks ORDER BY check_name;

SELECT CASE WHEN bool_and(passed) THEN 'adoption checks passed'
            ELSE error('MinIO adoption failed; inspect lake_bootstrap_checks and resolve manually without replacing existing state')
       END AS result
FROM lake_bootstrap_checks;

-- Read-only adoption proof for the existing per-laptop MinIO ingress.
-- It does not create/restart/reconfigure a container, bucket, Keychain item, or
-- DuckDB secret. Missing or mismatched required state fails the final check.
--
-- The inspect template emits only named non-secret fields. In particular, it
-- never serializes Config.Env, which contains the MinIO root password.

LOAD shellfs;

CREATE OR REPLACE TEMP TABLE lake_bootstrap_checks AS
WITH inspected AS (
  SELECT container_name, configured_image, state,
         api_host, api_port, console_host, console_port,
         data_source, data_target, image_id
  FROM read_csv($cmd$(docker inspect --format '{{printf "%s\t%s\t%s\t" .Name .Config.Image .State.Status}}{{range index .HostConfig.PortBindings "9000/tcp"}}{{printf "%s\t%s\t" .HostIp .HostPort}}{{else}}{{printf "\t\t"}}{{end}}{{range index .HostConfig.PortBindings "9001/tcp"}}{{printf "%s\t%s\t" .HostIp .HostPort}}{{else}}{{printf "\t\t"}}{{end}}{{$source := ""}}{{$target := ""}}{{range .Mounts}}{{if eq .Destination "/data"}}{{$source = .Source}}{{$target = .Destination}}{{end}}{{end}}{{printf "%s\t%s\t%s" $source $target .Image}}' duckstack-minio 2>/dev/null || podman inspect --format '{{printf "%s\t%s\t%s\t" .Name .Config.Image .State.Status}}{{range index .HostConfig.PortBindings "9000/tcp"}}{{printf "%s\t%s\t" .HostIp .HostPort}}{{else}}{{printf "\t\t"}}{{end}}{{range index .HostConfig.PortBindings "9001/tcp"}}{{printf "%s\t%s\t" .HostIp .HostPort}}{{else}}{{printf "\t\t"}}{{end}}{{$source := ""}}{{$target := ""}}{{range .Mounts}}{{if eq .Destination "/data"}}{{$source = .Source}}{{$target = .Destination}}{{end}}{{end}}{{printf "%s\t%s\t%s" $source $target .Image}}' duckstack-minio 2>/dev/null) |$cmd$,
    delim := chr(9), header := false,
    columns := {
      'container_name':'VARCHAR', 'configured_image':'VARCHAR', 'state':'VARCHAR',
      'api_host':'VARCHAR', 'api_port':'VARCHAR',
      'console_host':'VARCHAR', 'console_port':'VARCHAR',
      'data_source':'VARCHAR', 'data_target':'VARCHAR', 'image_id':'VARCHAR'
    }, ignore_errors := true)
),
fields AS (
  SELECT inspected.*
  FROM (SELECT 1 AS anchor) a LEFT JOIN inspected ON true
),
repo_digests AS (
  SELECT array_agg(repo_digest) FILTER (WHERE repo_digest IS NOT NULL) AS digests
  FROM read_csv($cmd$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$(docker inspect --format '{{.Image}}' duckstack-minio 2>/dev/null)" 2>/dev/null || podman image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$(podman inspect --format '{{.Image}}' duckstack-minio 2>/dev/null)" 2>/dev/null) |$cmd$,
    header := false, columns := {'repo_digest':'VARCHAR'}, ignore_errors := true)
),
health AS (
  SELECT max(response) AS response
  FROM read_csv('curl --silent --output /dev/null --write-out "%{http_code}" http://127.0.0.1:9100/minio/health/live 2>/dev/null |',
                header := false, columns := {'response':'VARCHAR'}, ignore_errors := true)
),
checks AS (
  SELECT 'producer_id' AS check_name,
         nullif(getenv('DUCKSTACK_PRODUCER_ID'), '') IS NOT NULL AS passed,
         coalesce(nullif(getenv('DUCKSTACK_PRODUCER_ID'), ''), '<unset>') AS observed,
         'Set DUCKSTACK_PRODUCER_ID explicitly; never infer a device identity.' AS expected,
         true AS required
  UNION ALL
  SELECT 'container_present', container_name IN ('duckstack-minio', '/duckstack-minio'),
         coalesce(container_name, '<missing>'), 'duckstack-minio', true FROM fields
  UNION ALL
  SELECT 'container_running', state = 'running', coalesce(state, '<missing>'), 'running', true FROM fields
  UNION ALL
  SELECT 'loopback_api', api_host = '127.0.0.1' AND api_port = '9100',
         coalesce(api_host, '<missing>') || ':' || coalesce(api_port, '<missing>'), '127.0.0.1:9100', true FROM fields
  UNION ALL
  SELECT 'loopback_console', console_host = '127.0.0.1' AND console_port = '9101',
         coalesce(console_host, '<missing>') || ':' || coalesce(console_port, '<missing>'), '127.0.0.1:9101', true FROM fields
  UNION ALL
  SELECT 'data_mount', data_source = getenv('HOME') || '/.duck/minio/data' AND data_target = '/data',
         coalesce(data_source, '<missing>') || ' -> ' || coalesce(data_target, '<missing>'),
         getenv('HOME') || '/.duck/minio/data -> /data', true FROM fields
  UNION ALL
  SELECT 'running_image_id', image_id IS NOT NULL, coalesce(image_id, '<missing>'),
         'Immutable local image ID for the running container', true FROM fields
  UNION ALL
  SELECT 'configured_image_ref', position('@sha256:' IN configured_image) > 0,
         coalesce(configured_image, '<missing>'), 'Configured OCI digest reference', false FROM fields
  UNION ALL
  SELECT 'observed_repo_digests', digests IS NOT NULL AND len(digests) > 0,
         coalesce(digests::VARCHAR, '<missing>'), 'RepoDigest(s) for the inspected running image ID', true FROM repo_digests
  UNION ALL
  SELECT 'api_health', coalesce(response = '200', false), coalesce(response, '<unavailable>'), '200', true FROM health
)
SELECT * FROM checks;

SELECT * FROM lake_bootstrap_checks ORDER BY check_name;

SELECT CASE WHEN bool_and(passed) FILTER (WHERE required) THEN 'adoption checks passed'
            ELSE error('MinIO adoption failed; inspect lake_bootstrap_checks and resolve manually without replacing existing state')
       END AS result
FROM lake_bootstrap_checks;

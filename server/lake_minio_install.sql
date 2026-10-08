-- Fresh-laptop MinIO bootstrap, with strict adoption of matching existing state.
-- Run with DuckDB on macOS. ShellFS is the only process boundary; no standalone
-- shell or Python files are created. All ShellFS output is status/metadata only.
-- Existing named containers are never stopped, removed, or recreated.

INSTALL shellfs FROM community;
LOAD shellfs;
INSTALL scalarfs FROM community;
LOAD scalarfs;
INSTALL httpfs;
LOAD httpfs;

-- Inspect both supported engines without exposing container environment values.
-- If both engines can see different containers with this name, the final check
-- fails before any write. An identical object exposed through Docker-compatible
-- Podman is treated as one container and Docker is selected as the client.
CREATE OR REPLACE TEMP TABLE minio_preflight AS
WITH raw AS (
  SELECT line
  FROM read_csv($cmd$
    docker_id="$(docker inspect --format '{{.Id}}' duckstack-minio 2>/dev/null)"
    podman_id="$(podman inspect --format '{{.Id}}' duckstack-minio 2>/dev/null)"
    if [ -n "$docker_id" ] && [ -n "$podman_id" ] && [ "$docker_id" != "$podman_id" ]; then
      printf 'conflicting_engines\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\n'
      exit 0
    fi
    if docker info >/dev/null 2>&1; then engine=docker
    elif podman info >/dev/null 2>&1; then engine=podman
    else printf 'missing\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\n'; exit 0
    fi
    if [ -n "$docker_id" ]; then engine=docker; inspect="$docker_id"
    elif [ -n "$podman_id" ]; then engine=podman; inspect="$podman_id"
    else inspect=""
    fi
    if [ -n "$inspect" ]; then
      "$engine" inspect --format '{{printf "%s\t%s\t%s\t" .Name .State.Status .Config.Image}}{{range index .HostConfig.PortBindings "9000/tcp"}}{{printf "%s\t%s\t" .HostIp .HostPort}}{{else}}{{printf "\t\t"}}{{end}}{{range index .HostConfig.PortBindings "9001/tcp"}}{{printf "%s\t%s\t" .HostIp .HostPort}}{{else}}{{printf "\t\t"}}{{end}}{{$source := ""}}{{$target := ""}}{{range .Mounts}}{{if eq .Destination "/data"}}{{$source = .Source}}{{$target = .Destination}}{{end}}{{end}}{{printf "%s\t%s\t%s\t%v" $source $target $.Image $.Args}}' "$inspect" 2>/dev/null | while IFS= read -r fields; do printf '%s\t%s\n' "$engine" "$fields"; done
    else
      printf '%s\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\n' "$engine"
    fi |
    $cmd$,
    header := false, delim := chr(9), quote := '', columns := {'line':'VARCHAR'},
    ignore_errors := true
  )
),
parsed AS (
  SELECT split(line, chr(9)) AS f FROM raw
)
SELECT
  nullif(f[1], '') AS engine,
  nullif(f[2], '') AS container_name,
  nullif(f[3], '') AS state,
  nullif(f[4], '') AS image_ref,
  nullif(f[5], '') AS api_host,
  nullif(f[6], '') AS api_port,
  nullif(f[7], '') AS console_host,
  nullif(f[8], '') AS console_port,
  nullif(f[9], '') AS data_source,
  nullif(f[10], '') AS data_target,
  nullif(f[11], '') AS image_id,
  nullif(f[12], '') AS executable
FROM parsed;

-- Local checks report booleans and never print credentials or listener process data.
CREATE OR REPLACE TEMP TABLE minio_local_checks AS
WITH paths AS (
  SELECT line
  FROM read_csv($cmd$
    data="$HOME/.duck/minio/data"
    if [ -L "$data" ]; then printf 'symlink\n'
    elif [ ! -e "$data" ]; then printf 'absent\n'
    elif [ ! -d "$data" ]; then printf 'not_directory\n'
    elif [ -z "$(find "$data" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then printf 'empty\n'
    else printf 'populated\n'; fi |
    $cmd$,
    header := false, delim := chr(31), quote := '', columns := {'line':'VARCHAR'}
  )
),
ports AS (
  SELECT line
  FROM read_csv($cmd$
    api="free"
    console="free"
    lsof -nP -iTCP:9100 -sTCP:LISTEN >/dev/null 2>&1 && api="busy"
    lsof -nP -iTCP:9101 -sTCP:LISTEN >/dev/null 2>&1 && console="busy"
    printf '%s\t%s\n' "$api" "$console" |
    $cmd$,
    header := false, delim := chr(9), quote := '', columns := {'line':'VARCHAR'}
  )
),
keychain AS (
  SELECT line
  FROM read_csv($cmd$(security find-generic-password -s duckstack-minio-root-password -a duckstack >/dev/null 2>&1 && printf 'present\n' || printf 'absent\n') |$cmd$,
    header := false, delim := chr(31), quote := '', columns := {'line':'VARCHAR'}
  )
),
creds AS (
  SELECT line
  FROM read_csv($cmd$
    engine="$(docker info >/dev/null 2>&1 && printf docker || printf podman)"
    docker_id="$(docker inspect --format '{{.Id}}' duckstack-minio 2>/dev/null)"
    podman_id="$(podman inspect --format '{{.Id}}' duckstack-minio 2>/dev/null)"
    if [ -n "$docker_id" ]; then engine=docker; target="$docker_id"
    elif [ -n "$podman_id" ]; then engine=podman; target="$podman_id"
    else printf 'not_applicable\n'; exit 0; fi
    expected="$(security find-generic-password -w -s duckstack-minio-root-password -a duckstack 2>/dev/null)"
    actual="$("$engine" inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$target" 2>/dev/null | sed -n 's/^MINIO_ROOT_PASSWORD=//p')"
    user="$("$engine" inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$target" 2>/dev/null | sed -n 's/^MINIO_ROOT_USER=//p')"
    if [ -n "$expected" ] && [ "$expected" = "$actual" ] && [ "$user" = duckstack ]; then printf 'match\n'; else printf 'mismatch\n'; fi |
    $cmd$,
    header := false, delim := chr(31), quote := '', columns := {'line':'VARCHAR'}, ignore_errors := true
  )
),
checks AS (
  SELECT 'engine_available' AS check_name, engine IN ('docker','podman') AS passed,
         coalesce(engine,'missing') AS observed FROM minio_preflight
  UNION ALL SELECT 'container_name', container_name IS NULL OR container_name IN ('duckstack-minio','/duckstack-minio'),
         coalesce(container_name,'absent') FROM minio_preflight
  UNION ALL SELECT 'container_running', container_name IS NULL OR state='running',
         coalesce(state,'absent') FROM minio_preflight
  UNION ALL SELECT 'image_is_minio', container_name IS NULL OR (position('minio' IN lower(image_ref))>0 AND image_id IS NOT NULL AND contains(executable,'server') AND contains(executable,'/data')),
         coalesce(image_ref,'absent') FROM minio_preflight
  UNION ALL SELECT 'loopback_api', container_name IS NULL OR (api_host='127.0.0.1' AND api_port='9100'),
         coalesce(api_host,'absent') || ':' || coalesce(api_port,'') FROM minio_preflight
  UNION ALL SELECT 'loopback_console', container_name IS NULL OR (console_host='127.0.0.1' AND console_port='9101'),
         coalesce(console_host,'absent') || ':' || coalesce(console_port,'') FROM minio_preflight
  UNION ALL SELECT 'data_mount', container_name IS NULL OR (data_source=getenv('HOME') || '/.duck/minio/data' AND data_target='/data'),
         coalesce(data_source,'absent') || ' -> ' || coalesce(data_target,'') FROM minio_preflight
  UNION ALL SELECT 'new_install_ports_free', container_name IS NOT NULL OR (api.line='free' AND console.line='free'),
         api.line || '/' || console.line FROM ports api CROSS JOIN ports console
  UNION ALL SELECT 'data_directory_safe', container_name IS NOT NULL OR p.line IN ('absent','empty'), p.line FROM paths p
  UNION ALL SELECT 'keychain_present_for_adoption', container_name IS NULL OR k.line='present', k.line FROM keychain k CROSS JOIN minio_preflight
  UNION ALL SELECT 'container_keychain_match', container_name IS NULL OR c.line='match', c.line FROM creds c CROSS JOIN minio_preflight
  UNION ALL SELECT 'no_engine_name_conflict', engine!='conflicting_engines', coalesce(engine,'missing') FROM minio_preflight
)
SELECT * FROM checks;

SELECT * FROM minio_preflight;
SELECT * FROM minio_local_checks ORDER BY check_name;
SELECT CASE WHEN bool_and(coalesce(passed,false)) THEN 'preflight passed'
            ELSE error('MinIO bootstrap refused: resolve the failed minio_local_checks without replacing existing state')
       END AS result
FROM minio_local_checks;

-- Create the Keychain credential only after every preflight gate passed. Existing
-- items are preserved. The generated password is captured inside ShellFS and no
-- command result contains it.
CREATE OR REPLACE TEMP TABLE minio_keychain_stage AS
SELECT line
FROM read_csv($cmd$
  if security find-generic-password -s duckstack-minio-root-password -a duckstack >/dev/null 2>&1; then
    printf 'existing\n'
  else
    password="$(openssl rand -hex 32)" || exit 1
    [ -n "$password" ] || exit 1
    security add-generic-password -s duckstack-minio-root-password -a duckstack -w "$password" >/dev/null 2>&1 || exit 1
    printf 'created\n'
  fi |
  $cmd$,
  header := false, delim := chr(31), quote := '', columns := {'line':'VARCHAR'}, ignore_errors := true
);

SELECT CASE WHEN line IN ('existing','created') THEN line
            ELSE error('MinIO bootstrap could not prepare the macOS Keychain item') END AS keychain
FROM minio_keychain_stage;

-- Create only missing directories. A populated or symlinked path was rejected above.
CREATE OR REPLACE TEMP TABLE minio_directory_stage AS
SELECT line
FROM read_csv($cmd$
  mkdir -p "$HOME/.duck/minio" || exit 1
  if [ ! -d "$HOME/.duck/minio/data" ]; then mkdir "$HOME/.duck/minio/data" || exit 1; fi
  printf 'ready\n' |
  $cmd$,
  header := false, delim := chr(31), quote := '', columns := {'line':'VARCHAR'}, ignore_errors := true
);

SELECT CASE WHEN line='ready' THEN line ELSE error('MinIO data directory preparation failed') END AS data_directory
FROM minio_directory_stage;

-- Start MinIO only when no named container was found. The image is immutable and
-- the API and console bind to loopback only. No stop/rm/recreate command exists here.
CREATE OR REPLACE TEMP TABLE minio_container_stage AS
SELECT line
FROM read_csv($cmd$
  docker_id="$(docker inspect --format '{{.Id}}' duckstack-minio 2>/dev/null)"
  podman_id="$(podman inspect --format '{{.Id}}' duckstack-minio 2>/dev/null)"
  if [ -n "$docker_id" ] || [ -n "$podman_id" ]; then printf 'adopted\n'; exit 0; fi
  if docker info >/dev/null 2>&1; then engine=docker; else engine=podman; fi
  image=quay.io/minio/minio@sha256:14cea493d9a34af32f524e538b8346cf79f3321eff8e708c1e2960462bd8936e
  "$engine" pull "$image" >/dev/null 2>&1 || exit 1
  password="$(security find-generic-password -w -s duckstack-minio-root-password -a duckstack 2>/dev/null)" || exit 1
  [ -n "$password" ] || exit 1
  MINIO_ROOT_PASSWORD="$password" "$engine" run --detach --name duckstack-minio \
    --publish 127.0.0.1:9100:9000 --publish 127.0.0.1:9101:9001 \
    --volume "$HOME/.duck/minio/data:/data" --env MINIO_ROOT_USER=duckstack \
    --env MINIO_ROOT_PASSWORD "$image" server /data --console-address :9001 \
    >/dev/null 2>&1 || exit 1
  printf 'created\n' |
  $cmd$,
  header := false, delim := chr(31), quote := '', columns := {'line':'VARCHAR'}, ignore_errors := true
);

SELECT CASE WHEN line IN ('adopted','created') THEN line
            ELSE error('MinIO container start failed; no existing container was replaced') END AS container
FROM minio_container_stage;

-- Wait for health without returning response bodies or credentials.
CREATE OR REPLACE TEMP TABLE minio_health_stage AS
SELECT line
FROM read_csv($cmd$
  n=0
  while [ "$n" -lt 45 ]; do
    if curl --silent --fail --connect-timeout 1 --max-time 2 http://127.0.0.1:9100/minio/health/live >/dev/null 2>&1; then
      printf 'healthy\n'; exit 0
    fi
    n=$((n + 1)); sleep 1
  done
  printf 'unhealthy\n' |
  $cmd$,
  header := false, delim := chr(31), quote := '', columns := {'line':'VARCHAR'}
);

SELECT CASE WHEN line='healthy' THEN line ELSE error('MinIO did not become healthy on 127.0.0.1:9100') END AS health
FROM minio_health_stage;

-- Use a pinned, disposable MinIO client sharing the MinIO container's network
-- namespace. Keychain data is handed through an environment variable; it is not
-- embedded in SQL, stdout, or Docker's command arguments.
CREATE OR REPLACE TEMP TABLE minio_bucket_stage AS
SELECT line
FROM read_csv($cmd$
  engine="$(docker info >/dev/null 2>&1 && printf docker || printf podman)"
  docker_id="$(docker inspect --format '{{.Id}}' duckstack-minio 2>/dev/null)"
  podman_id="$(podman inspect --format '{{.Id}}' duckstack-minio 2>/dev/null)"
  if [ -n "$docker_id" ]; then engine=docker; else engine=podman; fi
  client=quay.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727
  password="$(security find-generic-password -w -s duckstack-minio-root-password -a duckstack 2>/dev/null)" || exit 1
  [ -n "$password" ] || exit 1
  url_password="$(printf '%s' "$password" | od -An -tu1 | awk '{for (i=1;i<=NF;i++){b=$i;if((b>=48&&b<=57)||(b>=65&&b<=90)||(b>=97&&b<=122)||b==45||b==46||b==95||b==126)printf "%c",b;else printf "%%%02X",b}}')" || exit 1
  export MC_HOST_duckstack="http://duckstack:${url_password}@127.0.0.1:9000"
  "$engine" pull "$client" >/dev/null 2>&1 || exit 1
  "$engine" run --rm --network container:duckstack-minio --env MC_HOST_duckstack "$client" mb --ignore-existing duckstack/duckstack-local >/dev/null 2>&1 || exit 1
  version="$("$engine" run --rm --network container:duckstack-minio --env MC_HOST_duckstack "$client" version info duckstack/duckstack-local 2>/dev/null)" || version=""
  case "$version" in
    *enabled*) printf 'versioned\n' ;;
    *)
      "$engine" run --rm --network container:duckstack-minio --env MC_HOST_duckstack "$client" version enable duckstack/duckstack-local >/dev/null 2>&1 || exit 1
      version="$("$engine" run --rm --network container:duckstack-minio --env MC_HOST_duckstack "$client" version info duckstack/duckstack-local 2>/dev/null)" || exit 1
      case "$version" in *enabled*) printf 'versioned\n';; *) printf 'not_versioned\n';; esac
      ;;
  esac |
  $cmd$,
  header := false, delim := chr(31), quote := '', columns := {'line':'VARCHAR'}, ignore_errors := true
);

SELECT CASE WHEN line='versioned' THEN line ELSE error('MinIO bucket creation or versioning failed') END AS bucket
FROM minio_bucket_stage;

-- Capture the Keychain secret in a connection-local DuckDB variable. ShellFS
-- emits its bytes only to the variable sink; they never become query output.
COPY (
  SELECT password
  FROM read_csv(
    '/usr/bin/security find-generic-password -w -s duckstack-minio-root-password -a duckstack |',
    header := false, delim := chr(31), quote := '', columns := {'password':'VARCHAR'}
  )
) TO 'variable:duckstack_minio_password' (FORMAT variable, LIST none);

CREATE OR REPLACE SECRET minio_local (
  TYPE S3,
  KEY_ID 'duckstack',
  SECRET getvariable('duckstack_minio_password'),
  REGION 'us-east-1',
  ENDPOINT '127.0.0.1:9100',
  URL_STYLE 'path',
  USE_SSL false,
  SCOPE 's3://duckstack-local/'
);

-- DuckDB-level proof: write one unique Parquet object to S3 and read that same
-- object back. The key is unique per run; no existing object is overwritten.
CREATE OR REPLACE TEMP TABLE minio_smoke_expected AS
SELECT uuid()::VARCHAR AS probe_id,
       'duckstack_minio_bootstrap' AS event,
       current_timestamp AS recorded_at;

COPY (SELECT probe_id FROM minio_smoke_expected)
  TO 'variable:minio_smoke_probe' (FORMAT variable, LIST none);

COPY minio_smoke_expected TO 's3://duckstack-local/bootstrap/'
  (FORMAT parquet, PARTITION_BY (probe_id), FILENAME_PATTERN 'data-{uuid}.parquet');

CREATE OR REPLACE TEMP TABLE minio_smoke_readback AS
SELECT *
FROM read_parquet(
  's3://duckstack-local/bootstrap/probe_id=' || getvariable('minio_smoke_probe') || '/*.parquet',
  hive_partitioning=true
)
WHERE event='duckstack_minio_bootstrap'
  AND probe_id::VARCHAR=getvariable('minio_smoke_probe')::VARCHAR;

SELECT CASE
         WHEN len(list(r.probe_id))=1 AND list(r.probe_id)[1]::VARCHAR=e.probe_id::VARCHAR THEN 'pass'
         ELSE error('MinIO DuckDB Parquet write/readback did not match')
       END AS s3_round_trip,
       e.probe_id
FROM minio_smoke_expected e CROSS JOIN minio_smoke_readback r
GROUP BY e.probe_id;

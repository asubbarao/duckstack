-- One bounded batch. The outbox survives process restarts; all remote writes are
-- conditional creates, followed by byte-for-byte readback. No overwrite/delete.
ALTER TABLE agents.lake_outbox ADD COLUMN IF NOT EXISTS publish_lease UUID;
ALTER TABLE agents.lake_outbox ADD COLUMN IF NOT EXISTS publish_started_at TIMESTAMPTZ;
-- Connectivity is checked before claiming outbox rows. An expired AWS login or
-- unavailable S3 must not consume the five bounded publication attempts.
-- With an empty queue the command is local `printf idle`, so no AWS work runs.
LOAD scalarfs;
COPY (
  WITH work AS (
    SELECT coalesce(bool_or(status IN ('pending','failed','publishing') AND attempts < 5), false) AS has_work
    FROM agents.lake_outbox
  )
  SELECT CASE WHEN has_work THEN
    $cmd$((/opt/homebrew/bin/aws s3api head-bucket --bucket inframe-duckstack-785081088852 --region us-west-2 --cli-connect-timeout 3 --cli-read-timeout 5 > /dev/null 2>&1 && printf ready) || printf waiting) |$cmd$
    ELSE 'printf idle |' END AS command
  FROM work
) TO 'variable:lake_publish_probe_command' (FORMAT variable, LIST none);
CREATE TEMP TABLE lake_publish_connectivity AS
SELECT status = 'ready' AS ready
FROM read_csv(getvariable('lake_publish_probe_command'),
  header := false, delim := chr(31), quote := '', columns := {'status':'VARCHAR'});
CREATE TEMP TABLE lake_publish_batch AS
SELECT * EXCLUDE(publish_lease, publish_started_at), uuid() AS publish_lease, now() AS publish_started_at FROM agents.lake_outbox
WHERE EXISTS (SELECT 1 FROM lake_publish_connectivity WHERE ready)
  AND CASE WHEN status IN ('pending','failed') THEN true
           WHEN status='publishing' AND publish_started_at IS NULL THEN true
           WHEN status='publishing' THEN publish_started_at < now() - INTERVAL '30 minutes'
           ELSE false END
  AND attempts < 5
  AND length(producer) BETWEEN 1 AND 64
  AND translate(producer, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-', '') = ''
  AND length(publication_id) BETWEEN 1 AND 128
  AND translate(publication_id, 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-', '') = ''
  AND length(sha256) = 64 AND translate(sha256, '0123456789abcdef', '') = ''
  AND byte_size BETWEEN 1 AND 16777216
  AND local_uri = printf('s3://duckstack-local/shared/%s.parquet', publication_id)
  AND remote_uri = printf('s3://inframe-duckstack-785081088852/raw/%s/%s.parquet', producer, publication_id)
ORDER BY created_at, publication_id LIMIT 10;

UPDATE agents.lake_outbox o SET status = 'publishing', attempts = o.attempts + 1,
 publish_lease=b.publish_lease, publish_started_at=b.publish_started_at
FROM lake_publish_batch b WHERE o.publication_id = b.publication_id
  AND o.status=b.status AND o.attempts=b.attempts;

CREATE TEMP TABLE lake_publish_dispatch AS
WITH commands AS (
  SELECT b.publication_id, b.publish_lease, replace(replace(replace(replace($shell$
/bin/bash -c '
set -uo pipefail
id=@ID@; producer=@PRODUCER@; expected_sha=@SHA@; expected_size=@SIZE@
outcome=failed; reason=initializing; version=""; manifest_version=""; copied=false
emit() { jq -cn --arg id "$id" --arg outcome "$outcome" --arg reason "$reason" --arg version "$version" --arg mv "$manifest_version" --argjson copied "$copied" "{publication_id:\$id,outcome:\$outcome,reason:\$reason,version_id:\$version,manifest_version_id:\$mv,copied:\$copied}"; }
tmp=$(mktemp -d /tmp/duckstack-publish.XXXXXXXX) || { emit; exit 0; }
trap "rm -f \"$tmp/source\" \"$tmp/remote\" \"$tmp/manifest\" \"$tmp/head\" \"$tmp/get\" \"$tmp/put\" \"$tmp/error\"; rmdir \"$tmp\"" EXIT
export AWS_REGION=us-west-2 AWS_DEFAULT_REGION=us-west-2 AWS_PAGER="" AWS_MAX_ATTEMPTS=2
unset AWS_ENDPOINT_URL AWS_ENDPOINT_URL_S3
src() { env -u AWS_SESSION_TOKEN AWS_ACCESS_KEY_ID=duckstack AWS_SECRET_ACCESS_KEY="$(security find-generic-password -w -s duckstack-minio-root-password -a duckstack)" AWS_REGION=us-east-1 AWS_DEFAULT_REGION=us-east-1 aws --endpoint-url http://127.0.0.1:9100 --cli-connect-timeout 5 --cli-read-timeout 20 "$@"; }
cloud() { aws --cli-connect-timeout 5 --cli-read-timeout 20 "$@"; }
src s3 cp "s3://duckstack-local/shared/$id.parquet" "$tmp/source" --only-show-errors > /dev/null 2> "$tmp/error" || { reason=source_read_failed; emit; exit 0; }
actual_sha=$(shasum -a 256 "$tmp/source"); actual_sha=${actual_sha%% *}
actual_size=$(wc -c < "$tmp/source" | tr -d " ")
if test "$actual_sha" != "$expected_sha" || test "$actual_size" != "$expected_size"; then outcome=conflict; reason=source_integrity; emit; exit 0; fi
ensure_object() {
  file=$1; key=$2
  if ! cloud s3api head-object --bucket inframe-duckstack-785081088852 --key "$key" > "$tmp/head" 2> "$tmp/error"; then
    if ! grep -q "(404)" "$tmp/error"; then reason=remote_probe_failed; return 1; fi
    if cloud s3api put-object --bucket inframe-duckstack-785081088852 --key "$key" --body "$file" --if-none-match "*" > "$tmp/put" 2> "$tmp/error"; then copied=true; fi
    # Whether put succeeded or its response was lost, reconcile by reading.
  fi
  cloud s3api get-object --bucket inframe-duckstack-785081088852 --key "$key" "$tmp/remote" > "$tmp/get" 2> "$tmp/error" || { reason=remote_read_failed; return 1; }
  cmp -s "$file" "$tmp/remote" || { outcome=conflict; reason=remote_content_conflict; return 1; }
  object_version=$(jq -r ".VersionId // empty" "$tmp/get")
  test -n "$object_version" || { reason=missing_version_id; return 1; }
}
ensure_object "$tmp/source" "raw/$producer/$id.parquet" || { emit; exit 0; }; version=$object_version
jq -cn --arg id "$id" --arg producer "$producer" --arg sha "$expected_sha" --argjson size "$expected_size" --arg uri "s3://inframe-duckstack-785081088852/raw/$producer/$id.parquet" "{publication_id:\$id,producer:\$producer,sha256:\$sha,byte_size:\$size,remote_uri:\$uri}" > "$tmp/manifest"
ensure_object "$tmp/manifest" "manifests/$producer/$id.json" || { emit; exit 0; }; manifest_version=$object_version
outcome=published; reason=verified; emit
' |
$shell$, '@ID@', b.publication_id), '@PRODUCER@', b.producer), '@SHA@', b.sha256), '@SIZE@', b.byte_size::VARCHAR) AS command
  FROM lake_publish_batch b JOIN agents.lake_outbox o USING(publication_id, publish_lease)
), statements AS (
  SELECT *, printf('FROM read_json(%s, format=''newline_delimited'');',
      chr(39) || replace(trim(command, chr(10)||chr(13)||' '), chr(39), chr(39)||chr(39)) || chr(39)) AS statement
  FROM commands
), fired AS (
  SELECT publication_id, publish_lease, statement,
         http_post_form('http://localhost:9495/sql', MAP {}, MAP {'sql': statement}) AS response
  FROM statements
)
SELECT publication_id, publish_lease, statement, response.status::INTEGER AS executor_status,
       from_json(response.body, '"VARCHAR"') AS raw_response FROM fired;

CREATE TABLE IF NOT EXISTS agents.lake_publish_attempts AS
SELECT now() AS observed_at, * FROM lake_publish_dispatch LIMIT 0;
ALTER TABLE agents.lake_publish_attempts ADD COLUMN IF NOT EXISTS publish_lease UUID;
INSERT INTO agents.lake_publish_attempts BY NAME
SELECT now() AS observed_at, * FROM lake_publish_dispatch;

CREATE TEMP TABLE lake_publish_receipts AS
SELECT d.*, receipt
FROM lake_publish_dispatch d CROSS JOIN UNNEST(
  try_cast(CASE WHEN executor_status = 200 THEN raw_response ELSE '[]' END AS
    STRUCT(publication_id VARCHAR, outcome VARCHAR, reason VARCHAR, version_id VARCHAR,
           manifest_version_id VARCHAR, copied BOOLEAN)[])
) r(receipt);

UPDATE agents.lake_outbox o
SET status = CASE WHEN r.receipt.outcome = 'published' THEN 'published'
                  WHEN r.receipt.outcome = 'conflict' THEN 'conflict' ELSE 'failed' END,
    attempts = CASE WHEN r.receipt.reason IN ('source_read_failed','remote_probe_failed','remote_read_failed')
                    THEN o.attempts - 1 ELSE o.attempts END,
    receipt = json_object('result', r.receipt, 'raw_response', r.raw_response),
    last_error = CASE WHEN r.receipt.outcome = 'published' THEN NULL ELSE r.receipt.reason END
FROM lake_publish_receipts r
WHERE o.publication_id = r.publication_id AND r.receipt.publication_id = o.publication_id
  AND o.publish_lease=r.publish_lease AND o.status='publishing';

UPDATE agents.lake_outbox o SET status = 'failed', last_error = 'dispatch_failed',
  receipt = json_object('executor_status', d.executor_status, 'raw_response', d.raw_response)
FROM lake_publish_dispatch d
WHERE o.publication_id = d.publication_id AND o.publish_lease=d.publish_lease AND o.status = 'publishing';

SELECT o.* FROM agents.lake_outbox o JOIN lake_publish_batch b USING(publication_id);

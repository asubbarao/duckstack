-- Google Drive publishing on the existing QuackAPI. LOAD quackapi and shellfs before this file.
-- POST /drive/publish  folder=<local dir>  parent=<Drive folder id>  [name=<new folder name, default basename>]
-- Creates <name> under <parent> (Shared Drives included) and uploads every regular, non-hidden file in <folder>
-- into it; one JSON receipt row for the folder and one per file. A contributor cannot move a folder into a Shared
-- Drive, but can create one there and upload into it, which is why the route never moves.
-- The token is loaded per call from gcloud's stored refresh token (one-time `gcloud auth login <account>
-- --enable-gdrive-access`) and lives only in the bash process: never in SQL, the database or a stored secret.
-- Google access tokens expire hourly, so this is not a startup secret like github_http in setup.sql.
CREATE OR REPLACE ROUTE drive_publish POST '/drive/publish'
PARAM folder VARCHAR PARAM parent VARCHAR PARAM name VARCHAR DEFAULT ''
AS SELECT * FROM read_json(
  '/bin/bash -s -- ' || chr(39) || replace($folder, chr(39), chr(39) || '\' || chr(39) || chr(39)) || chr(39)
  || ' ' || chr(39) || replace($parent, chr(39), '') || chr(39)
  || ' ' || chr(39) || replace($name, chr(39), chr(39) || '\' || chr(39) || chr(39)) || chr(39)
  || $drive$ 2>/dev/null <<'DRIVE_7f3a'
set -euo pipefail
DIR="$1"; PARENT="$2"; NAME="${3:-}"; [ -n "$NAME" ] || NAME=$(basename "$DIR")
TOKEN=$(/opt/homebrew/bin/gcloud auth print-access-token)
API=https://www.googleapis.com
META=$(/usr/bin/jq -cn --arg n "$NAME" --arg p "$PARENT" '{name:$n, mimeType:"application/vnd.google-apps.folder", parents:[$p]}')
FOLDER=$(curl -sS -X POST "$API/drive/v3/files?supportsAllDrives=true&fields=id,name,parents" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" --data "$META")
FID=$(printf '%s' "$FOLDER" | /usr/bin/jq -r .id)
printf '%s' "$FOLDER" | /usr/bin/jq -c '{kind:"folder", id, name, url:("https://drive.google.com/drive/folders/" + .id), error}'
find "$DIR" -maxdepth 1 -type f ! -name '.*' -print0 | sort -z | xargs -0 -n1 -I{} /bin/bash -c '
  M=$(/usr/bin/jq -cn --arg n "$(basename "$1")" --arg p "$2" "{name:\$n, parents:[\$p]}")
  curl -sS -X POST "$3/upload/drive/v3/files?uploadType=multipart&supportsAllDrives=true&fields=id,name,size,md5Checksum" \
    -H "Authorization: Bearer $4" -F "metadata=$M;type=application/json;charset=UTF-8" -F "file=@$1" \
  | /usr/bin/jq -c "{kind:\"file\", id, name, size, md5Checksum, error}"' _ {} "$FID" "$API" "$TOKEN"
DRIVE_7f3a
|$drive$, format := 'newline_delimited', union_by_name := true);

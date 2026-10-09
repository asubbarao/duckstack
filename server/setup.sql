-- setup.sql: the dev DuckDB. launchd runs `duckdb ~/.duck/dev.duckdb -init setup.sql`; a second instance is the same
-- file with DEV_QUACK_PORT / DEV_QUACKAPI_PORT / DEV_MCP_PORT set. Everything is inline here, cron jobs included.
-- Order matters: secrets settings precede every LOAD; the lock is last.
SET GLOBAL home_directory = getenv('HOME');
SET GLOBAL extension_directory = getenv('HOME') || '/.duck/extensions';
SET GLOBAL secret_directory = getenv('HOME') || '/.duck/secrets';

INSTALL quack; LOAD quack; INSTALL httpfs; LOAD httpfs; INSTALL aws; LOAD aws; INSTALL encodings; INSTALL ducklake;
-- Sentry's event JSON endpoint is read through DuckDB's HTTP filesystem. Keep the
-- credential in the launchd environment and create only an in-memory, scoped
-- secret at startup so read_json/read_json_auto can authenticate without a
-- token in SQL or the database file.
SET VARIABLE sentry_auth_token = nullif(getenv('SENTRY_AUTH_TOKEN'), '');
CREATE TEMPORARY SECRET sentry_http (
    TYPE HTTP,
    BEARER_TOKEN getvariable('sentry_auth_token'),
    SCOPE 'https://us.sentry.io'
);
RESET VARIABLE sentry_auth_token;
-- Keep the other local API credentials in the launchd environment as well,
-- but expose them to DuckDB HTTP readers through scoped secrets. The values
-- are never written into setup.sql or the database; getenv() is evaluated at
-- service startup and the temporary variables are cleared immediately.
SET VARIABLE github_api_token = nullif(getenv('GITHUB_TOKEN'), '');
CREATE TEMPORARY SECRET github_http (
    TYPE HTTP,
    BEARER_TOKEN getvariable('github_api_token'),
    SCOPE 'https://api.github.com'
);
RESET VARIABLE github_api_token;
SET VARIABLE slack_api_token = nullif(getenv('SLACK_TOKEN'), '');
CREATE TEMPORARY SECRET slack_http (
    TYPE HTTP,
    BEARER_TOKEN getvariable('slack_api_token'),
    SCOPE 'https://slack.com'
);
RESET VARIABLE slack_api_token;
SET VARIABLE linear_api_token = nullif(getenv('LINEAR_API_KEY'), '');
CREATE TEMPORARY SECRET linear_http (
    TYPE HTTP,
    BEARER_TOKEN getvariable('linear_api_token'),
    SCOPE 'https://api.linear.app'
);
RESET VARIABLE linear_api_token;
LOAD json; LOAD icu; LOAD parquet; INSTALL fts; LOAD fts; INSTALL postgres; LOAD postgres; INSTALL sqlite; LOAD sqlite;
INSTALL webbed FROM community; LOAD webbed; INSTALL markdown FROM community; LOAD markdown;
-- DuckDB 1.5.6 (2026-10-08): crawler, prometheus, cloudwatch, quack_flamegraph have no v1.5.6 build yet (404 on
-- community-extensions.duckdb.org/v1.5.6/osx_arm64). Restore their INSTALL/LOAD once published.
INSTALL cronjob FROM community; LOAD cronjob;
INSTALL splink_udfs FROM community; LOAD splink_udfs; INSTALL urlpattern FROM community; LOAD urlpattern;
INSTALL netquack FROM community; LOAD netquack; INSTALL shellfs FROM community; LOAD shellfs;
INSTALL tera FROM community; LOAD tera; INSTALL scalarfs FROM community; LOAD scalarfs;
INSTALL http_client FROM community; LOAD http_client; INSTALL otlp FROM community; LOAD otlp;
INSTALL observefs FROM community; LOAD observefs; INSTALL lance; LOAD lance;
INSTALL agent_data FROM community; LOAD agent_data; INSTALL duck_tails FROM community; LOAD duck_tails;
INSTALL duck_hunt FROM community; LOAD duck_hunt; INSTALL zipfs FROM community; LOAD zipfs;
INSTALL quickjs FROM community; LOAD quickjs; INSTALL miniplot FROM community; LOAD miniplot;
INSTALL minijinja FROM community; LOAD minijinja; INSTALL gh FROM community; LOAD gh;
INSTALL hostfs FROM community; LOAD hostfs; INSTALL pdf FROM community; LOAD pdf;
INSTALL parser_tools FROM community; LOAD parser_tools; INSTALL yaml FROM community; LOAD yaml;
INSTALL jsonata FROM community; LOAD jsonata; INSTALL sitting_duck FROM community; LOAD sitting_duck; INSTALL curl_httpfs FROM community; LOAD curl_httpfs;
INSTALL sazgar FROM community; LOAD sazgar;
-- One local durable catalog; PostgreSQL remains the business-profile authority.
LOAD ducklake;
ATTACH IF NOT EXISTS 'ducklake:/Users/aloksubbarao/.duck/lake/duckstack/catalog.ducklake' AS lake
  (DATA_PATH '/Users/aloksubbarao/.duck/lake/duckstack/data/', DATA_INLINING_ROW_LIMIT 0);
CREATE SCHEMA IF NOT EXISTS lake.raw;
CREATE SCHEMA IF NOT EXISTS lake.agent;
CREATE SCHEMA IF NOT EXISTS lake.agents;
CREATE SCHEMA IF NOT EXISTS lake.history;
CREATE SCHEMA IF NOT EXISTS lake.ops;
-- Recreate only reader names; the catalog is the sole owner of these rows.
CREATE SCHEMA IF NOT EXISTS agents;
CREATE SCHEMA IF NOT EXISTS agent;
CREATE OR REPLACE VIEW agents.ext_page AS FROM lake.agents.ext_page;
CREATE OR REPLACE VIEW agents.ext_fetch AS FROM lake.agents.ext_fetch;
CREATE OR REPLACE VIEW agent.stream AS FROM lake.agent.stream;
CREATE SCHEMA IF NOT EXISTS meta;

-- A laptop tenant: leave memory and cores for the desktop; bounded temp; UTC; patient HTTP; fewer checkpoint pauses.
SET GLOBAL memory_limit = '8GB'; SET GLOBAL threads = 10; SET GLOBAL scheduler_process_partial = true;
SET GLOBAL allocator_background_threads = true; SET GLOBAL temp_directory = getenv('HOME') || '/.duck/tmp';
SET GLOBAL max_temp_directory_size = '50GiB'; SET GLOBAL TimeZone = 'UTC'; SET GLOBAL checkpoint_threshold = '128MiB';
-- No retries: cron is serial, and a stalled reader call (quack_query to 19494) held every job for timeout x retries.
SET GLOBAL http_timeout = 120; SET GLOBAL http_retries = 0; SET GLOBAL http_retry_wait_ms = 0;
SET GLOBAL httpfs_connection_caching = true; SET enable_progress_bar = false; PRAGMA enable_checkpoint_on_shutdown;
-- No query may trigger a silent download; profiling stays settable after the lock; no Hugging Face reads.
SET GLOBAL autoinstall_known_extensions = false; SET GLOBAL allowed_configs = ['enable_profiling', 'profiling_coverage'];
SET GLOBAL disabled_filesystems = 'HuggingFaceFileSystem';

-- Every query on this instance, to one CSV. quackapi_serve switches logging off, so it is applied again after serving.
-- enable_logging(types, level, storage, storage_config, storage_path, storage_normalize, storage_buffer_size)
-- One identity for the process lifetime, shared by native logs and its supervisor.
CREATE TABLE IF NOT EXISTS meta.server_instances (
    instance_id VARCHAR PRIMARY KEY, started_at TIMESTAMPTZ, wrapper_pid BIGINT,
    engine_version VARCHAR, extensions JSON, native_log_path VARCHAR
);
INSERT INTO meta.server_instances BY NAME
SELECT coalesce(nullif(getenv('QUACK_INSTANCE_ID'), ''), 'legacy') AS instance_id,
       now() AS started_at,
       try_cast(getenv('QUACK_WRAPPER_PID') AS BIGINT) AS wrapper_pid,
       version() AS engine_version, to_json(list(e)) AS extensions,
       coalesce(nullif(getenv('QUACK_NATIVE_LOG'), ''),
                getenv('HOME') || '/.duck/logs/duckdb_log.csv') AS native_log_path
FROM duckdb_extensions() e WHERE loaded
ON CONFLICT DO NOTHING;

CREATE OR REPLACE VIEW meta.current_server AS
FROM meta.server_instances
QUALIFY row_number() OVER (ORDER BY started_at DESC) = 1;

-- Filled by setup.sql after the listeners are chosen.  MCP exposes this relation so an
-- agent can identify the exact disposable instance it reached instead of assuming ports.
CREATE TABLE IF NOT EXISTS meta.runtime_endpoints (
    service VARCHAR PRIMARY KEY, address VARCHAR, recorded_at TIMESTAMPTZ
);
SET VARIABLE log_path = coalesce(nullif(getenv('QUACK_NATIVE_LOG'), ''), getenv('HOME') || '/.duck/logs/duckdb_log.csv');
CALL enable_logging(['QueryLog', 'HTTP', 'Quack', 'Metrics'], storage := 'file', storage_path := getvariable('log_path'), storage_buffer_size := 0);
CREATE OR REPLACE VIEW query_log AS SELECT * EXCLUDE (type, message), message AS query FROM duckdb_logs WHERE type = 'QueryLog';
CREATE OR REPLACE VIEW http_log AS FROM duckdb_logs_parsed('HTTP');
CREATE OR REPLACE VIEW quack_log AS FROM duckdb_logs_parsed('Quack');
CREATE OR REPLACE VIEW metrics_log AS FROM duckdb_logs_parsed('Metrics');

-- Serve: quack (token from the environment; unset fails closed), quackapi /sql + OTLP routes, the dev MCP.
SET VARIABLE quack_uri = 'quack:localhost:' || coalesce(nullif(getenv('DEV_QUACK_PORT'), ''), '9494');
SET VARIABLE quackapi_port = coalesce(nullif(getenv('DEV_QUACKAPI_PORT'), ''), '9495')::INTEGER;
SET VARIABLE mcp_port = coalesce(nullif(getenv('DEV_MCP_PORT'), ''), '9496')::INTEGER;
SET VARIABLE otlp_dir = getenv('HOME') || '/.duck/otlp';
CALL quack_identify(name := 'dev', hostname := 'localhost', region := 'local', provider := 'local', meta := '{"role": "dev-duckdb"}');
CREATE OR REPLACE TABLE _quack_serve AS SELECT now() AS started_at, listen_uri, listen_url FROM quack_serve(getvariable('quack_uri'), token := getenv('QUACK_TOKEN'));
INSTALL quackapi FROM community; LOAD quackapi;
-- Opt-in incubator SQL executor and typed browser-capture handoff.
-- Raw SQL execution is a trusted-local capability. Never expose it unauthenticated
-- to a network. This executor accepts SELECT programs, not arbitrary DDL batches.
CREATE OR REPLACE ROUTE acquisition_incubator_sql POST '/acquisition-incubator/sql'
AS SELECT * FROM query($sql);

-- Connector/browser capture handoff. Transport clients own capture and readiness;
-- QuackAPI validates the fields and preserves the original JSON body as a receipt.
CREATE OR REPLACE ROUTE acquisition_incubator_capture POST '/acquisition-incubator/capture'
PARAM target VARCHAR PARAM document VARCHAR
PARAM title VARCHAR DEFAULT '' PARAM ready_state VARCHAR DEFAULT ''
AS SELECT $target::VARCHAR AS target, $title::VARCHAR AS title,
          $ready_state::VARCHAR AS ready_state, $body::JSON AS receipt,
          $document::HTML AS document;
-- Synthetic HTTP fixtures only: no real account, credentials or mutation targets.
CREATE OR REPLACE ROUTE acquisition_incubator_page GET '/acquisition-incubator/page'
AS SELECT '<!doctype html><title>Acquisition incubator fixture</title><base href="/acquisition-incubator/"><h1 id="fixture">Fixture café</h1><a href="rows">Rows</a>' AS html;

CREATE OR REPLACE ROUTE acquisition_incubator_login POST '/acquisition-incubator/login'
AS SELECT 'incubator_demo=fixture; Path=/acquisition-incubator; HttpOnly; SameSite=Lax' AS set_cookie,
          'fixture login' AS result;

CREATE OR REPLACE ROUTE acquisition_incubator_protected GET '/acquisition-incubator/protected'
PARAM incubator_demo VARCHAR COOKIE
AS SELECT CASE WHEN $incubator_demo = 'fixture'
               THEN '<h1>Cookie session accepted</h1><a href="rows">Rows</a>'
               ELSE error('Wrong fixture cookie') END AS html;

CREATE OR REPLACE ROUTE acquisition_incubator_rows GET '/acquisition-incubator/rows'
AS SELECT range AS id, 'fixture' AS source FROM range(3);
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
-- POST /call_models (+ /render). Helper streams via SaveImageWebsocket → image_b64 (zero Mac disk).
CREATE OR REPLACE ROUTE call_models POST '/call_models'
PARAM prompt VARCHAR
PARAM negative VARCHAR DEFAULT ''
PARAM width VARCHAR DEFAULT '1024'
PARAM height VARCHAR DEFAULT '1024'
PARAM steps VARCHAR DEFAULT '20'
PARAM seed VARCHAR DEFAULT ''
PARAM ckpt VARCHAR DEFAULT 'lustifySDXLNSFWSFW_v20.safetensors'
PARAM engine VARCHAR DEFAULT 'mps'
AS SELECT * FROM read_json(
  '/Users/aloksubbarao/ComfyUI/.venv/bin/python /Users/aloksubbarao/duckdb-skills/server/routes/comfy_generate.py'
  || ' --prompt-b64 ' || to_base64(encode(coalesce($prompt, '')))
  || ' --negative-b64 ' || to_base64(encode(coalesce(nullif($negative, ''), ' ')))
  || ' --width ' || regexp_replace(coalesce(nullif($width, ''), '1024'), '[^0-9]', '', 'g')
  || ' --height ' || regexp_replace(coalesce(nullif($height, ''), '1024'), '[^0-9]', '', 'g')
  || ' --steps ' || regexp_replace(coalesce(nullif($steps, ''), '20'), '[^0-9]', '', 'g')
  || ' --seed ' || regexp_replace(coalesce(nullif($seed, ''), '0'), '[^0-9]', '', 'g')
  || ' --model ' || regexp_replace(coalesce(nullif($ckpt, ''), 'lustifySDXLNSFWSFW_v20.safetensors'), '[^A-Za-z0-9._-]', '', 'g')
  || ' --engine ' || regexp_replace(coalesce(nullif($engine, ''), 'mps'), '[^A-Za-z0-9._-]', '', 'g')
  || ' --return-b64 1'
  || ' |'
);

CREATE OR REPLACE ROUTE render POST '/render'
PARAM prompt VARCHAR
PARAM negative VARCHAR DEFAULT ''
PARAM width VARCHAR DEFAULT '1024'
PARAM height VARCHAR DEFAULT '1024'
PARAM steps VARCHAR DEFAULT '20'
PARAM seed VARCHAR DEFAULT ''
PARAM ckpt VARCHAR DEFAULT 'lustifySDXLNSFWSFW_v20.safetensors'
PARAM engine VARCHAR DEFAULT 'mps'
AS SELECT * FROM read_json(
  '/Users/aloksubbarao/ComfyUI/.venv/bin/python /Users/aloksubbarao/duckdb-skills/server/routes/comfy_generate.py'
  || ' --prompt-b64 ' || to_base64(encode(coalesce($prompt, '')))
  || ' --negative-b64 ' || to_base64(encode(coalesce(nullif($negative, ''), ' ')))
  || ' --width ' || regexp_replace(coalesce(nullif($width, ''), '1024'), '[^0-9]', '', 'g')
  || ' --height ' || regexp_replace(coalesce(nullif($height, ''), '1024'), '[^0-9]', '', 'g')
  || ' --steps ' || regexp_replace(coalesce(nullif($steps, ''), '20'), '[^0-9]', '', 'g')
  || ' --seed ' || regexp_replace(coalesce(nullif($seed, ''), '0'), '[^0-9]', '', 'g')
  || ' --model ' || regexp_replace(coalesce(nullif($ckpt, ''), 'lustifySDXLNSFWSFW_v20.safetensors'), '[^A-Za-z0-9._-]', '', 'g')
  || ' --engine ' || regexp_replace(coalesce(nullif($engine, ''), 'mps'), '[^A-Za-z0-9._-]', '', 'g')
  || ' --return-b64 1'
  || ' |'
);
CREATE OR REPLACE VIEW agents.path_aliases AS
SELECT 'asubbarao.github' AS alias, 'ASUBBARAO_GITHUB_ROOT' AS environment_variable,
       'git://' || nullif(getenv('ASUBBARAO_GITHUB_ROOT'), '') AS root;
FROM quack_query(getvariable('quack_uri'),
  replace(replace($routes$
CREATE OR REPLACE ROUTE sql POST '/sql'
  AS SELECT * FROM quack_query('@QUACK_URI', $session$SET enable_profiling = 'no_output';
SET profiling_coverage = 'ALL';
SET VARIABLE "asubbarao.github" = 'git://' || nullif(getenv('ASUBBARAO_GITHUB_ROOT'), '');
$session$ || $sql, token := getenv('QUACK_TOKEN'));
CREATE OR REPLACE ROUTE otlp_logs POST '/v1/logs' AS
  COPY (SELECT $body::VARCHAR AS payload, 'logs' AS signal) TO '@OTLP_DIR'
  (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', PARTITION_BY (signal), FILENAME_PATTERN '{uuid}', FILE_EXTENSION 'json', OVERWRITE_OR_IGNORE true);
CREATE OR REPLACE ROUTE otlp_traces POST '/v1/traces' AS
  COPY (SELECT $body::VARCHAR AS payload, 'traces' AS signal) TO '@OTLP_DIR'
  (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', PARTITION_BY (signal), FILENAME_PATTERN '{uuid}', FILE_EXTENSION 'json', OVERWRITE_OR_IGNORE true);
CREATE OR REPLACE ROUTE otlp_metrics POST '/v1/metrics' AS
  COPY (SELECT $body::VARCHAR AS payload, 'metrics' AS signal) TO '@OTLP_DIR'
  (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', PARTITION_BY (signal), FILENAME_PATTERN '{uuid}', FILE_EXTENSION 'json', OVERWRITE_OR_IGNORE true);
-- One empty payload per signal, so the unified view binds on a fresh instance (a glob that
-- matches nothing fails CREATE VIEW); it reads as zero rows.
COPY (SELECT '{"resourceLogs":[]}' AS payload, 'logs' AS signal
      UNION ALL SELECT '{"resourceSpans":[]}', 'traces'
      UNION ALL SELECT '{"resourceMetrics":[]}', 'metrics')
TO '@OTLP_DIR' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '', PARTITION_BY (signal),
                FILENAME_PATTERN '_seed', FILE_EXTENSION 'json', OVERWRITE_OR_IGNORE true);
CREATE OR REPLACE ROUTE inbox POST '/inbox' AS
  COPY (SELECT json_object('received_at', now(), 'source', coalesce(b ->> 'source', 'unknown'), 'kind', b ->> 'kind',
                           'payload', b) AS line FROM (SELECT json($body::VARCHAR) AS b))
  TO '| cat >> /Users/aloksubbarao/.duck/raw/inbox/inbox.ndjson' (FORMAT csv, HEADER false, QUOTE '', ESCAPE '');
SELECT 'routes ok' AS routes
$routes$, '@QUACK_URI', getvariable('quack_uri')), '@OTLP_DIR', getvariable('otlp_dir')),
  token := getenv('QUACK_TOKEN'));
-- Agent inbox: POST /inbox with any JSON body {"source", "kind", ...}. The route above appends one compact line per
-- post to inbox.ndjson, the durable record. Read it as agent_inbox or `tail -n0 -F` the file. No `--` comment may
-- sit inside the $routes$ batch before a CREATE ROUTE: quackapi's parser does not skip it and setup fails.
-- The file exists before its view binds; an empty file reads as zero rows.
FROM read_text('mkdir -p /Users/aloksubbarao/.duck/raw/inbox && touch /Users/aloksubbarao/.duck/raw/inbox/inbox.ndjson |');
CREATE OR REPLACE VIEW agent_inbox AS
SELECT received_at, source, kind, payload, filename
FROM read_json('/Users/aloksubbarao/.duck/raw/inbox/inbox.ndjson', format = 'newline_delimited', filename = true,
               columns = {received_at: 'TIMESTAMPTZ', source: 'VARCHAR', kind: 'VARCHAR', payload: 'JSON'});
-- Local LLM chat on the already-running Ollama; no companion app server or inference process.
CREATE OR REPLACE ROUTE local_llm_chat POST '/llm/chat'
  PARAM prompt VARCHAR MIN_LENGTH 1 MAX_LENGTH 32000
  PARAM model VARCHAR DEFAULT 'qwen3.6:35b'
  PARAM think BOOLEAN DEFAULT false
  PARAM max_tokens INTEGER DEFAULT 512 GE 1 LE 4096
  PARAM history VARCHAR DEFAULT '[]'
AS
WITH upstream AS (
  SELECT quackapi_post(
    'http://127.0.0.1:11434/api/chat',
    to_json({
      model: $model::VARCHAR,
      messages: list_append(
        from_json($history::VARCHAR, '[{"role":"VARCHAR","content":"VARCHAR"}]'),
        {role: 'user', content: $prompt::VARCHAR}
      ),
      think: $think::BOOLEAN,
      stream: false,
      options: {num_predict: $max_tokens::INTEGER},
      keep_alive: 0
    })::VARCHAR
  ) AS receipt
),
decoded AS (
  SELECT receipt,
         try(from_json(receipt.body, '{"model":"VARCHAR","message":{"content":"VARCHAR","thinking":"VARCHAR","tool_calls":["JSON"]},"done":"BOOLEAN","done_reason":"VARCHAR","total_duration":"BIGINT","load_duration":"BIGINT","eval_count":"BIGINT","eval_duration":"BIGINT","error":"VARCHAR"}')) AS result
  FROM upstream
)
SELECT result.model AS model, result.message.content AS answer,
       result.done AS done, result.done_reason AS finish_reason,
       result.total_duration / 1000000.0 AS total_ms,
       result.load_duration / 1000000.0 AS load_ms,
       result.eval_count AS output_tokens,
       receipt.status AS upstream_status,
       coalesce(nullif(receipt.error, ''), result.error) AS error,
       receipt AS raw_receipt
FROM decoded;

LOAD tera;
CREATE OR REPLACE ROUTE local_llm_chat_page GET '/llm/chat' AS
SELECT tera_render($page$
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{ title }}</title>
<style>
:root{color-scheme:dark;--bg:#151719;--panel:#202326;--line:#363b40;--text:#f0eee9;--muted:#a1a8ad;--accent:#e7bf78}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.6 system-ui,-apple-system,sans-serif}
main{max-width:900px;margin:auto;padding:34px 24px 28px}header{display:flex;align-items:center;justify-content:space-between;gap:18px;margin-bottom:30px}
h1{font-size:23px;line-height:1.2;letter-spacing:-.6px;margin:0 0 6px}p{margin:0}.sub,.meta{color:var(--muted);font-size:13px}
.badge{color:var(--accent);border:1px solid #554a35;border-radius:30px;padding:4px 11px;font-size:12px;white-space:nowrap}
button{font:inherit;cursor:pointer;border:1px solid var(--line);border-radius:10px;padding:8px 14px;background:transparent;color:var(--text)}button:hover{border-color:var(--accent)}button:disabled{opacity:.45;cursor:wait}
#empty{padding:65px 10px 45px;text-align:center;color:var(--muted)}#empty h2{color:var(--text);font-size:24px;font-weight:500;margin:0 0 10px}.suggestions{display:flex;justify-content:center;gap:9px;margin-top:22px;flex-wrap:wrap}.suggestions button{font-size:13px}
article{margin:0 0 22px;padding:19px 21px;background:var(--panel);border:1px solid var(--line);border-radius:14px}article.user{background:transparent;border-color:#34383b}.role{color:var(--accent);font-size:11px;font-weight:650;letter-spacing:1px;text-transform:uppercase;margin-bottom:7px}
.content{white-space:pre-wrap;overflow-wrap:anywhere}.meta{margin-top:12px}.error{color:#f2a39b}
form{margin-top:24px;background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:14px}textarea{resize:vertical;min-height:115px;max-height:400px;width:100%;border:0;outline:0;background:transparent;color:var(--text);font:16px/1.6 inherit;line-height:1.6;padding:5px 6px}
.bar{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:9px 4px 0}.hint{font-size:12px;color:var(--muted)}#send{background:var(--accent);color:#211d16;border:0;font-weight:650;padding:8px 23px}#status{font-size:13px;color:var(--muted);min-height:23px;margin:10px 4px 0}
@media(max-width:600px){main{padding:22px 14px}header{align-items:flex-start}.hint{display:none}article{padding:15px}.badge{font-size:11px}}
</style>
</head>
<body><main>
<header><div><h1>{{ title }}</h1><p class="sub">{{ model_label }} · thinking off</p></div><div><span class="badge">On this Mac</span> <button id="clear" type="button">New chat</button></div></header>
<div id="messages" aria-live="polite"></div>
<section id="empty"><h2>What are you working on?</h2><p>Ask a question, paste code, or share an error.</p><div class="suggestions"><button type="button" data-prompt="Help me debug this error:\n">Debug an error</button><button type="button" data-prompt="Explain this code:\n">Explain code</button><button type="button" data-prompt="Help me troubleshoot yt-dlp HTTP 403 for a video I own.">Troubleshoot yt-dlp</button></div></section>
<form id="composer"><textarea id="prompt" aria-label="Message" placeholder="Message your local model…" maxlength="32000" required autofocus></textarea><div class="bar"><span class="hint">⌘ Enter or Ctrl Enter to send</span><button id="send" type="submit">Send</button></div></form>
<p id="status" role="status"></p>
</main>
<script>
const form=document.getElementById('composer'),input=document.getElementById('prompt'),send=document.getElementById('send'),clear=document.getElementById('clear'),messages=document.getElementById('messages'),empty=document.getElementById('empty'),status=document.getElementById('status');
let history=[],busy=false;
function addMessage(role,text,metadata){const article=document.createElement('article');article.className=role;const label=document.createElement('div');label.className='role';label.textContent=role==='user'?'You':'Local model';const content=document.createElement('div');content.className='content';content.textContent=text;article.append(label,content);if(metadata){const meta=document.createElement('div');meta.className='meta';meta.textContent=metadata;article.append(meta)}messages.append(article);empty.hidden=true;return article}
document.querySelectorAll('[data-prompt]').forEach(button=>button.addEventListener('click',()=>{input.value=button.dataset.prompt;input.focus()}));
clear.addEventListener('click',()=>{if(busy)return;history=[];messages.replaceChildren();empty.hidden=false;status.textContent='';input.value='';input.focus()});
input.addEventListener('keydown',event=>{if(event.key==='Enter'&&(event.metaKey||event.ctrlKey)){event.preventDefault();form.requestSubmit()}});
form.addEventListener('submit',async event=>{event.preventDefault();const prompt=input.value.trim();if(busy||!prompt)return;busy=true;send.disabled=true;clear.disabled=true;addMessage('user',prompt);input.value='';const started=Date.now();status.className='';status.textContent='Waiting for the local model…';const timer=setInterval(()=>{status.textContent='Waiting for the local model · '+Math.floor((Date.now()-started)/1000)+'s'},1000);
try{const response=await fetch(location.pathname,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({prompt,history:JSON.stringify(history)})});const payload=await response.json();if(!response.ok){const detail=payload.detail;throw new Error(Array.isArray(detail)?detail.map(item=>item.msg).join('; '):detail||'Request failed')}const result=Array.isArray(payload)?payload[0]:payload;if(result.error||result.upstream_status!==200)throw new Error(result.error||'The local model did not respond');if(!result.answer)throw new Error('The model returned no answer');let metadata=(result.total_ms/1000).toFixed(1)+'s · '+result.output_tokens+' tokens';if(result.load_ms>1000)metadata+=' · model loading '+(result.load_ms/1000).toFixed(1)+'s';if(result.finish_reason==='length')metadata+=' · output limit reached';addMessage('assistant',result.answer,metadata);history.push({role:'user',content:prompt},{role:'assistant',content:result.answer});status.textContent='';}
catch(error){status.className='error';status.textContent=error.message;input.value=prompt;}
finally{clearInterval(timer);busy=false;send.disabled=false;clear.disabled=false;input.focus();form.scrollIntoView({block:'nearest',behavior:'smooth'})}});
</script></body></html>
$page$, {title:'Local chat', model_label:'Qwen 3.6 35B'}::JSON) AS html;
-- ScalarFS may invoke only this local telemetry path resolver.
SET GLOBAL allowed_pathmacros = 'telemetry';
LOAD hostfs;
LOAD scalarfs;

-- Stable local telemetry URIs; HostFS discovers the current JSON files on every read.
-- telemetry(params MAP(VARCHAR, VARCHAR)) -> VARCHAR[]; only the three OTLP signals are accepted.
CREATE OR REPLACE MACRO telemetry(params) AS (
  SELECT array_agg(path ORDER BY path)
  FROM ls(getenv('HOME') || '/.duck/otlp/signal=' ||
          CASE WHEN params['signal'] IN ('logs', 'traces', 'metrics')
               THEN params['signal'] ELSE error('telemetry: signal must be logs, traces, or metrics') END)
  WHERE is_file(path) AND file_extension(path) = '.json'
);

CREATE OR REPLACE VIEW otlp_events AS
SELECT 'logs'::VARCHAR AS signal, NULL::VARCHAR AS metric_kind, *
FROM read_otlp_logs('pathmacro:telemetry?signal=logs')
UNION ALL BY NAME
SELECT 'traces'::VARCHAR AS signal, NULL::VARCHAR AS metric_kind, *
FROM read_otlp_traces('pathmacro:telemetry?signal=traces')
UNION ALL BY NAME
SELECT 'metrics'::VARCHAR AS signal, 'sum'::VARCHAR AS metric_kind, *
FROM read_otlp_metrics_sum('pathmacro:telemetry?signal=metrics')
UNION ALL BY NAME
SELECT 'metrics'::VARCHAR AS signal, 'gauge'::VARCHAR AS metric_kind, *
FROM read_otlp_metrics_gauge('pathmacro:telemetry?signal=metrics')
UNION ALL BY NAME
SELECT 'metrics'::VARCHAR AS signal, 'histogram'::VARCHAR AS metric_kind, *
FROM read_otlp_metrics_histogram('pathmacro:telemetry?signal=metrics')
UNION ALL BY NAME
SELECT 'metrics'::VARCHAR AS signal, 'exp_histogram'::VARCHAR AS metric_kind, *
FROM read_otlp_metrics_exp_histogram('pathmacro:telemetry?signal=metrics');

CREATE OR REPLACE TABLE _listeners AS SELECT now() AS at, 'quack' AS service, listen_uri AS address FROM quack_server_list()
    UNION ALL SELECT now(), 'quackapi', 'http://127.0.0.1:' || getvariable('quackapi_port')
    UNION ALL SELECT now(), 'mcp', 'http://localhost:' || getvariable('mcp_port') || '/mcp';
INSERT OR REPLACE INTO meta.runtime_endpoints (service, address, recorded_at)
SELECT service, address, "at" FROM _listeners;
-- Agent entry points. duckdb_mcp's built-in tools (query, describe, list_tables, database_info, export) run SQL in this
-- database; query adds no row cap, so callers write their own LIMIT. Published here: only what one query cannot express.
INSTALL duckdb_mcp FROM community; LOAD duckdb_mcp;
INSTALL http_client FROM community; LOAD http_client; INSTALL webbed FROM community; LOAD webbed;
INSTALL read_lines FROM community; LOAD read_lines; INSTALL scalarfs FROM community; LOAD scalarfs; LOAD quackapi;

-- agent.<reader> views (one per agent_data reader) → agent.source_all (cleaned, id, tool call as a column) →
-- lake.agent.stream, the only table; agent.stream is its read name. Search is BM25 over its Lance text copy.
-- id is the uuid; a row without one (Codex on some agent_data builds) uses file:line.
LOAD agent_data;

-- Stores: hostfs finds the directories agent_data detects on (projects/ → claude, sessions/ → codex,
-- local-agent-mode-sessions/ → claude-desktop). Readers: the extension's read_* table functions.
-- Cross join → one CREATE VIEW per reader over every store → self-dispatch to /sql. /sql serves only once setup
-- reaches its last line, so this runs as a cron job (every 10 minutes); the views persist in between.
SELECT cron($gen$WITH layout AS (
    SELECT '.claude' AS store_name, 'projects' AS marker, 'claude' AS source
    UNION ALL SELECT '.codex', 'sessions', 'codex'
    UNION ALL SELECT 'Claude', 'local-agent-mode-sessions', 'claude-desktop'
), listed AS (
    SELECT path FROM ls(getenv('HOME') || '/.claude')
    UNION ALL SELECT path FROM ls(getenv('HOME') || '/.codex')
    UNION ALL SELECT path FROM ls(getenv('HOME') || '/Library/Application Support/Claude')
), stores AS (
    SELECT chr(39) || l.source || chr(39) AS source_literal, chr(39) || parse_dirpath(f.path) || chr(39) AS store_literal
    FROM listed AS f JOIN layout AS l ON l.marker = file_name(f.path) AND l.store_name = file_name(parse_dirpath(f.path))
), readers AS (
    SELECT DISTINCT function_name AS reader_function, replace(function_name, 'read_', '') AS reader FROM duckdb_functions()
    WHERE function_type = 'table' AND function_name IN ('read_conversations', 'read_history', 'read_plans', 'read_todos', 'read_stats')
), stmt AS (
    SELECT r.reader, array_to_string(['CREATE OR REPLACE VIEW', 'agent.' || r.reader, 'AS', string_agg(array_to_string(
               ['SELECT * FROM', r.reader_function || '(source :=', s.source_literal || ', path :=', s.store_literal || ')'], ' '),
           ' UNION ALL BY NAME ')], ' ') AS sql
    FROM readers AS r CROSS JOIN stores AS s GROUP BY r.reader
), sent AS (
    SELECT array_agg({reader: reader, receipt: http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', sql))}) AS receipts FROM stmt
)
SELECT r.reader, r.receipt ->> '$.status' AS status FROM sent CROSS JOIN UNNEST(receipts) AS t(r)$gen$, '0 */10 * * * *');

CREATE OR REPLACE VIEW agent.source_all AS
WITH native AS (
    SELECT *, list_contains(list_transform(['business-profile', 'business_profile', 'customer_name', 'insured_name', 'policy_number'],
                lambda term: contains(lower(concat_ws(' ', message_content, tool_input, cwd, project_path, project_dir)), term)), true) AS privacy_redacted
    FROM agent.conversations
), roles AS (
    SELECT 'user' AS speaker, 'user' AS message_role
    UNION ALL SELECT 'assistant', 'agent' UNION ALL SELECT 'reasoning', 'agent' UNION ALL SELECT 'agent_message', 'agent'
    UNION ALL SELECT 'system', 'system' UNION ALL SELECT 'developer', 'system' UNION ALL SELECT 'tool', 'tool_result'
)
SELECT n.* REPLACE (
        CASE WHEN n.privacy_redacted AND n.message_content <> '' THEN '[redacted: client-data boundary]' ELSE nullif(n.message_content, '') END AS message_content,
        CASE WHEN n.privacy_redacted AND n.tool_input <> '' THEN '[redacted: client-data boundary]' ELSE nullif(n.tool_input, '') END AS tool_input,
        coalesce(r.message_role, 'other') AS message_role),
    n.source AS system, coalesce(n.uuid, n.file_name || ':' || n.line_number) AS id, n.message_role AS source_message_role,
    length(nullif(n.message_content, '')) AS content_length,
    CASE WHEN n.tool_name <> '' THEN {name: n.tool_name, input: n.tool_input, call_id: n.tool_use_id} END AS tool_data,
    try_cast(n.timestamp AS TIMESTAMPTZ) AS ts
FROM native AS n
LEFT JOIN roles AS r ON r.speaker = CASE WHEN n.message_role <> '' THEN n.message_role ELSE n.message_type END;

CREATE OR REPLACE VIEW agent.source AS SELECT * FROM agent.source_all WHERE ts > now() - INTERVAL 1 DAY;

PRAGMA mcp_publish_tool('stream_search',
  'BM25 search over agent messages (Claude and Codex). Best 10 by score: id, system, session, time, role, 200-char head. Full text: stream_message.',
  $$SELECT id, system, session_id, ts, message_role, round(_score, 2) AS score, left(message_content, 200) AS head
    FROM lance_fts('/Users/aloksubbarao/.duck/lance/stream.lance', 'message_content', $q, k := 10) ORDER BY _score DESC$$,
  '{"q":{"type":"string","description":"search words"}}', '["q"]', 'markdown');
PRAGMA mcp_publish_tool('stream_message',
  'The complete text of one agent.stream row by id (every other read of agent.stream should select heads, not message_content).',
  $$SELECT id, system, session_id, ts, message_role, tool_data, message_content, content_length FROM agent.stream WHERE id = $id$$,
  '{"id":{"type":"string"}}', '["id"]', 'markdown');

PRAGMA mcp_publish_tool('self_dispatch',
  'Row-driven execution. Pass a SELECT returning a statement column (plus any source keys); each returned row''s statement runs through dev /sql and comes back with its raw HTTP receipt. Zero rows means no calls. Dependent statements belong in one statement body. Never replay uncertain writes.',
  $$WITH statements AS (FROM query($rows_sql)),
posted AS (SELECT array_agg({source: statements, response: http_post(endpoint.address || '/sql', MAP {'Content-Type': 'application/json'}, json_object('sql', statement))}) AS receipts
           FROM statements JOIN meta.runtime_endpoints AS endpoint ON endpoint.service = 'quackapi')
SELECT r.source, r.source.statement AS statement, r.response.status AS status, r.response.body AS body FROM posted CROSS JOIN UNNEST(receipts) AS t(r)$$,
  '{"rows_sql":{"type":"string","description":"SELECT ... AS statement FROM ...; filter here before execution"}}', '["rows_sql"]', 'json');

PRAGMA mcp_publish_tool('shellfs',
  'Run a Bash program on the dev server and get its output lines (line_number, content). For structured output use query with read_csv or read_json over ''<command> |''. Nonzero exits are errors.',
  $$SELECT line_number, content FROM read_lines($command || ' |')$$,
  '{"command":{"type":"string","description":"Bash program; runs on the dev server"}}', '["command"]', 'markdown');

PRAGMA mcp_publish_tool('web_read',
  'Fetch a URL and return its readable blocks (headings, paragraphs, code, tables) in page order, with HTTP status and raw size, instead of raw HTML.',
  $$WITH page AS (SELECT r.status, length(r.body ->> '$') AS raw_chars, html_to_duck_blocks((r.body ->> '$')::HTML) AS blocks FROM (SELECT http_get($url) AS r))
SELECT status, raw_chars, b.element_order AS n, b.element_type AS type, trim(b.content) AS text
FROM page CROSS JOIN UNNEST(blocks) AS t(b) WHERE b.kind = 'block' AND length(trim(b.content)) > 0 ORDER BY n$$,
  '{"url":{"type":"string"}}', '["url"]', 'markdown');

PRAGMA mcp_publish_tool('render',
  'Render a Tera template on the dev server: an inline template string, or an absolute .tera path (siblings load for includes). ctx is a JSON object. Returns text; does not execute it.',
  $$SELECT CASE WHEN ends_with($template, '.tera')
    THEN tera_render(parse_filename($template), $ctx::JSON, autoescape := false, template_path := parse_dirpath($template) || '/*')
    ELSE tera_render($template, $ctx::JSON, autoescape := false) END AS rendered$$,
  '{"template":{"type":"string"},"ctx":{"type":"string","description":"JSON object"}}', '["template","ctx"]', 'text');

PRAGMA mcp_server_start('http', 'localhost', getvariable('mcp_port'),
  '{"builtin_tools": true, "background": true, "default_result_format": "markdown"}');

-- Native observability over DuckDB's own log (duckdb_logs reads the CSV setup.sql logs to; no archive, no ATTACH).
-- Quack already records the request, duration, response class and error; keep that shape.
CREATE OR REPLACE VIEW meta.quack_events AS
SELECT * EXCLUDE (message), unnest(parse_duckdb_log_message('Quack', message))
FROM duckdb_logs
WHERE type = 'Quack';

CREATE OR REPLACE VIEW meta.remote_query_history AS
SELECT timestamp AS started_at,
       quack_connection_id,
       client_query_id,
       query,
       duration_ms,
       duration_ms / 1000.0 AS wall_seconds,
       response_type,
       error
FROM meta.quack_events
WHERE message_type = 'PREPARE_REQUEST'
  AND server IS NULL
  AND client_query_id IS NOT NULL;

CREATE OR REPLACE VIEW meta.query_minute AS
SELECT time_bucket(INTERVAL 1 MINUTE, started_at) AS minute,
       len(list(started_at)) AS queries,
       len(list(started_at) FILTER (error IS NOT NULL)) AS errors,
       quantile_cont(duration_ms, 0.50) AS p50_ms,
       quantile_cont(duration_ms, 0.95) AS p95_ms,
       quantile_cont(duration_ms, 0.99) AS p99_ms,
       max(duration_ms) AS max_ms,
       sum(duration_ms) / 1000.0 AS wall_seconds
FROM meta.remote_query_history
GROUP BY ALL;

-- DuckDB processes, one row each per minute (sazgar_processes() columns as they come), a week kept.
CREATE TABLE IF NOT EXISTS meta.process_samples AS SELECT now() AS observed_at, * FROM sazgar_processes() LIMIT 0;
CREATE OR REPLACE VIEW meta.host_process_latest AS
SELECT * FROM meta.process_samples QUALIFY observed_at = max(observed_at) OVER ();
SELECT cron($$DELETE FROM meta.process_samples WHERE observed_at < now() - INTERVAL 7 DAY;
INSERT INTO meta.process_samples BY NAME SELECT now() AS observed_at, * FROM sazgar_processes() WHERE name = 'duckdb';
CREATE OR REPLACE TABLE meta.prometheus_snapshot AS SELECT now() AS observed_at, text FROM meta.prometheus_metrics$$, '0 * * * * *');

-- A single `text` column is emitted by quackapi as text/plain, which Prometheus can scrape.
CREATE OR REPLACE VIEW meta.prometheus_metrics AS
WITH query_totals AS (
  SELECT len(list(started_at)) AS queries,
         len(list(started_at) FILTER (error IS NOT NULL)) AS errors,
         sum(duration_ms) / 1000.0 AS wall_seconds
  FROM meta.remote_query_history
), archive AS (
  SELECT greatest(0, date_diff('millisecond', max(timestamp), now()) / 1000.0) AS lag_seconds
  FROM duckdb_logs
), memory AS (
  SELECT sum(memory_usage_bytes) AS tracked_bytes,
         sum(temporary_storage_bytes) AS temporary_bytes,
         string_agg(printf('duckdb_memory_usage_bytes{tag="%s"} %d', tag, memory_usage_bytes), chr(10)
                    ORDER BY tag) AS tag_lines
  FROM duckdb_memory()
), processes AS (
  SELECT len(list(pid)) AS process_count, sum(memory_percent) AS memory_percent
  FROM meta.host_process_latest
)
SELECT concat(
  '# HELP duckdb_quack_queries_total Quack queries archived by DuckDB.', chr(10),
  '# TYPE duckdb_quack_queries_total counter', chr(10),
  'duckdb_quack_queries_total ', queries, chr(10),
  '# HELP duckdb_quack_query_errors_total Quack query errors archived by DuckDB.', chr(10),
  '# TYPE duckdb_quack_query_errors_total counter', chr(10),
  'duckdb_quack_query_errors_total ', errors, chr(10),
  '# HELP duckdb_quack_query_wall_seconds_total Total Quack query wall time.', chr(10),
  '# TYPE duckdb_quack_query_wall_seconds_total counter', chr(10),
  'duckdb_quack_query_wall_seconds_total ', wall_seconds, chr(10),
  '# HELP duckdb_query_archive_lag_seconds Age of the newest archived native log row.', chr(10),
  '# TYPE duckdb_query_archive_lag_seconds gauge', chr(10),
  'duckdb_query_archive_lag_seconds ', lag_seconds, chr(10),
  '# HELP duckdb_memory_tracked_bytes Memory tracked by DuckDB memory managers.', chr(10),
  '# TYPE duckdb_memory_tracked_bytes gauge', chr(10),
  'duckdb_memory_tracked_bytes ', tracked_bytes, chr(10),
  '# HELP duckdb_temporary_storage_bytes Temporary storage tracked by DuckDB.', chr(10),
  '# TYPE duckdb_temporary_storage_bytes gauge', chr(10),
  'duckdb_temporary_storage_bytes ', temporary_bytes, chr(10),
  '# HELP duckdb_memory_usage_bytes DuckDB tracked memory by internal tag.', chr(10),
  '# TYPE duckdb_memory_usage_bytes gauge', chr(10),
  tag_lines, chr(10),
  '# HELP duckdb_processes Processes whose executable is DuckDB.', chr(10),
  '# TYPE duckdb_processes gauge', chr(10),
  'duckdb_processes ', process_count, chr(10),
  '# HELP duckdb_process_memory_percent_sum Host memory percent used by DuckDB processes.', chr(10),
  '# TYPE duckdb_process_memory_percent_sum gauge', chr(10),
  'duckdb_process_memory_percent_sum ', memory_percent, chr(10)
) AS text
FROM query_totals CROSS JOIN archive CROSS JOIN memory CROSS JOIN processes;

CREATE OR REPLACE TABLE meta.prometheus_snapshot AS
SELECT now() AS observed_at, text FROM meta.prometheus_metrics;

CREATE OR REPLACE ROUTE prometheus_metrics GET '/metrics'
AS SELECT text FROM meta.prometheus_snapshot;
-- Raw OS evidence survives a native crash; all interpretation remains in views.
-- CSVs include the final statements of processes that died before the archive cron ran.
CREATE OR REPLACE VIEW meta.native_logs AS
SELECT * FROM read_csv(getenv('HOME') || '/.duck/logs/duckdb_log*.csv',
    header := true, union_by_name := true, filename := true,
    max_line_size := 16777216,
    columns := {context_id: 'UBIGINT', scope: 'VARCHAR', connection_id: 'UBIGINT',
                transaction_id: 'UBIGINT', query_id: 'UBIGINT', thread_id: 'UBIGINT',
                timestamp: 'TIMESTAMPTZ', type: 'VARCHAR', log_level: 'VARCHAR', message: 'VARCHAR'});

CREATE OR REPLACE VIEW meta.server_query_log AS
SELECT i.instance_id, l.* FROM meta.native_logs l
LEFT JOIN meta.server_instances i ON l.filename = i.native_log_path
WHERE l.type = 'QueryLog';

CREATE OR REPLACE VIEW meta.server_events AS
SELECT f.file, l.line_number, l.content AS raw_line,
       try_cast(l.content AS JSON) AS event
FROM glob(getenv('HOME') || '/.duck/logs/server-events*.jsonl') f
CROSS JOIN LATERAL read_lines_lateral(f.file) l;

CREATE OR REPLACE VIEW meta.server_crash_files AS
SELECT file, file_size(file) AS bytes, file_last_modified(file) AS modified_at
FROM glob(getenv('HOME') || '/Library/Logs/DiagnosticReports/duckdb-*.ips');

CREATE OR REPLACE VIEW meta.server_crashes AS
WITH documents AS (
    SELECT f.file,
           string_agg(l.content, '' ORDER BY l.line_number) AS raw_report,
           string_agg(l.content, '' ORDER BY l.line_number)
               FILTER (WHERE l.line_number = 1)::JSON AS header,
           try_cast(string_agg(l.content, '' ORDER BY l.line_number)
               FILTER (WHERE l.line_number > 1) AS JSON) AS report
    FROM meta.server_crash_files f
    CROSS JOIN LATERAL read_lines_lateral(f.file) l
    GROUP BY f.file
)
SELECT *, try_cast(report->>'pid' AS BIGINT) AS pid,
       try_strptime(report->>'procLaunch', '%Y-%m-%d %H:%M:%S.%f %z') AS process_started_at,
       try_strptime(report->>'captureTime', '%Y-%m-%d %H:%M:%S.%f %z') AS captured_at,
       report->'exception' AS exception,
       report->'termination' AS termination,
       report->'threads' AS threads, report->'usedImages' AS images
FROM documents;

CREATE OR REPLACE VIEW meta.server_exits AS
SELECT file, line_number, raw_line, event,
       event->>'instance_id' AS instance_id,
       try_cast(event->>'pid' AS BIGINT) AS pid,
       try_cast(event->>'exit_status' AS INTEGER) AS exit_status
FROM meta.server_events WHERE event->>'event' = 'exit';

CREATE OR REPLACE VIEW meta.server_incidents AS
SELECT e.*, c.file AS crash_file, c.captured_at, c.exception, c.termination
FROM meta.server_exits e LEFT JOIN meta.server_crashes c
  ON e.pid = c.pid
 AND abs(date_diff('second', try_cast(e.event->>'at' AS TIMESTAMPTZ),
                  c.captured_at)) <= 60
WHERE e.exit_status IS DISTINCT FROM 0;
-- The Lance text copy that stream_search scores (a full overwrite, under 1 s). The stream ingest is not scheduled:
-- agent.source reads every transcript file (minutes) before filtering to a day.
SELECT cron($$COPY (SELECT id, system, session_id, ts, message_role, message_content FROM agent.stream WHERE message_content IS NOT NULL) TO '/Users/aloksubbarao/.duck/lance/stream.lance' (FORMAT lance, mode 'overwrite')$$, '30 */5 * * * *');
-- Checkpoint from its own connection: auto-checkpoint needs a quiet moment dev never has; a failed attempt
-- (another transaction open) is harmless and the next tick retries, so the WAL cannot grow for long.
SELECT cron('CHECKPOINT', '45 */5 * * * *');
-- Extension docs (every readthedocs.io site an extension README links to). Raw HTML lands once per page in
-- lake.agents.ext_fetch; daily, only pages not saved yet are fetched, one curl read each (readthedocs' Cloudflare
-- challenges http_client). Pages = each site root plus same-site page links (path ending in / or .html) of saved pages.
SELECT cron($$WITH seed AS (
    SELECT DISTINCT url_origin(l.url) || '/' AS url FROM agents.ext_docs, UNNEST(md_extract_links(readme)) AS t(l)
    WHERE urlpattern_test('https://*.readthedocs.io/*', l.url)
), saved AS (
    SELECT url, response ->> 'effective_url' AS effective_url, response ->> 'body' AS body
    FROM lake.agents.ext_fetch WHERE urlpattern_test('https://*.readthedocs.io/*', url)
), linked AS (
    SELECT effective_url AS base, url_parse(url_resolve(effective_url, a.href)) AS u
    FROM saved, UNNEST(html_extract_links(body::HTML)) AS t(a)
), wanted AS (
    SELECT url FROM seed
    UNION SELECT u.origin || u.pathname FROM linked
    WHERE u.origin = url_origin(base) AND len(list_filter(['/*/', '/*.html'], p -> urlpattern_test(u.origin || p, u.href))) > 0
), due AS (
    SELECT url, chr(39) || url || chr(39) AS url_literal FROM wanted ANTI JOIN saved USING (url)
)
SELECT url, http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'}, {'sql': array_to_string(
         ['INSERT INTO lake.agents.ext_fetch BY NAME SELECT', url_literal, 'AS url, now() AS fetched_at,',
          'json_object(''effective_url'', parts[2], ''body'', parts[1]) AS response',
          'FROM (SELECT string_split(content, chr(10) || ''@@effective_url '') AS parts',
          'FROM read_text(''curl -sfL -w "\n@@effective_url %{url_effective}"', url, '|''))'], ' ')}::JSON).status AS status
FROM due$$, '20 0 3 * * *');
-- One row per docs section, parsed from the saved HTML only: markdown sections with their code blocks and tables.
CREATE OR REPLACE VIEW agents.ext_doc_sections AS
WITH page AS (
    SELECT response ->> 'effective_url' AS url, duck_blocks_to_md(html_to_duck_blocks((response ->> 'body')::HTML)) AS markdown
    FROM lake.agents.ext_fetch WHERE urlpattern_test('https://*.readthedocs.io/*', url)
), section AS (
    SELECT url, unnest(md_extract_sections(markdown), recursive := true) FROM page
)
SELECT url_host(url) AS site, url || '#' || section_id AS section_url, section_path, level, title, content::VARCHAR AS content,
       md_extract_code_blocks(content) AS code, md_extract_tables_json(content) AS tables
FROM section;
-- The effective configuration, every start; then refuse to serve a crippled or over-permissive instance.
CREATE OR REPLACE TABLE _setup_settings AS SELECT now() AS recorded_at, * FROM duckdb_settings();
SELECT error('setup.sql: refusing to serve -- ' || name || ' = ' || value) FROM duckdb_settings()
WHERE name || '=' || value IN ('allow_community_extensions=false', 'enable_external_access=false',
    'allow_unsigned_extensions=true', 'allow_unredacted_secrets=true');
-- After this no connection can SET/PRAGMA/RESET; INSTALL, LOAD, ATTACH and HTTP still work.
-- Serve /sql and every route above. quackapi_serve resets DuckDB's logging (enable_logging false: off; true: stdout),
-- so the file logging is applied again right after it. Once quackapi leaves logging alone, this becomes the last
-- line with block := true and the wrapper's stdin keep-alive goes away.
CREATE OR REPLACE TABLE _quackapi_serve AS
SELECT now() AS started_at, * FROM quackapi_serve(getvariable('quackapi_port'), host := '127.0.0.1');
CALL enable_logging(['QueryLog', 'HTTP', 'Quack', 'Metrics'], storage := 'file', storage_path := getvariable('log_path'), storage_buffer_size := 0);
SET GLOBAL lock_configuration = true;


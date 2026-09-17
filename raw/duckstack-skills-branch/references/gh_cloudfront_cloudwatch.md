# duckdb-gh, duckdb-cloudfront, duckdb-cloudwatch — DuckDB community extension reference

Sources of truth: `<repo> duckdb-gh`, `<repo> duckdb-cloudfront`, `<repo> duckdb-cloudwatch` (READMEs, `docs/`, `src/`, `test/`, `.github/workflows/`). Where README and source disagree, **source wins**; every discrepancy is flagged `[DISCREPANCY]`. Function names, named parameters, secret types and return columns below are taken from the `RegisterFunction` / `named_parameters` / `SecretType` calls in `src/`, not from prose.

| Extension | Upstream | HEAD (local clone) | DuckDB pin (CI) | Registered surface |
|---|---|---|---|---|
| `gh` | `carlopi/duckdb-gh` | `10d642a` 2026-04-29 "Add gh_prs table function" | `v1.5-variegata` (DuckDB 1.5.x) | `gh://` filesystem, `gh_repo`, `gh_repos`, `gh_issues`, `gh_prs`, secret type `github` |
| `cloudfront` | `midwork-finds-jobs/duckdb-cloudfront` | `92f38d2` 2026-02-05 | `main` + scheduled `v1.4`/`v1.5` branch builds | secret type `cloudfront` (providers `config`, `env`), `cloudfront_version()` |
| `cloudwatch` | `smithclay/duckdb-cloudwatch` | `d0fa5b3` 2026-08-11 (PR #7 send_cloudwatch_metrics) | `v1.5.5`, ci-tools `v1.5-variegata`, **WASM excluded** | `ATTACH ... TYPE cloudwatch`, 4 table functions, 7 scalar write/admin functions, `cloudwatch_serve`/`cloudwatch_stop` |

---

## 1. `gh` — query GitHub from SQL

**What it is for.** A read-only virtual filesystem plus four table functions over the GitHub REST API. `gh://owner/repo@ref/path` works anywhere DuckDB takes a file path (`read_csv`, `read_parquet`, `read_json`, `glob`, `ATTACH ... (READ_ONLY)`), including recursive globs. `gh_repo`/`gh_repos` return repository metadata (one repo, a whole org, or a table of names), `gh_issues` and `gh_prs` paginate the issues/pulls endpoints into flat tables. It is a metadata/content reader, not a GitHub API client: no commits, releases, workflows, comments, or GraphQL, and it never writes. README header: "Experimental ... APIs, behaviour, and URL formats may change without notice."

**Install / load.**
```sql
-- README has no INSTALL line; it is built from source (GEN=ninja make) and loaded as a binary:
LOAD '/path/to/build/release/extension/gh/gh.duckdb_extension';   -- needs duckdb -unsigned / allow_unsigned_extensions
-- If/when it is published: INSTALL gh FROM community; LOAD gh;
```
`gh_extension.cpp` calls `ExtensionHelper::TryAutoLoadExtension(db, "httpfs")` and `"json"` at load: httpfs must already be **installed** (it supplies the HTTPS backend; gh does its own request building through `HTTPUtil`). Fails silently if not installed — the first `gh://` read then errors.

### 1.1 Filesystem prefix `gh://`

```
gh://owner/repo@ref/path/to/file     -- ref = branch, tag or commit SHA
gh://owner/repo/path/to/file         -- no ref: extension sends ref=HEAD (default branch)
```
Implementation facts (`github_filesystem.cpp`):
- Content is fetched via `GET https://api.github.com/repos/{o}/{r}/contents/{path}?ref={ref}` with `Accept: application/vnd.github.raw` (so private repos work with a token and files up to GitHub's ~100 MB Contents limit are served raw). **The whole file is buffered in memory at `OpenFile`** — no range reads, so a Parquet footer-only read still downloads the entire object.
- `OpenFile` for writing throws `GithubFileSystem is read-only: cannot open '...' for writing`. `ATTACH 'gh://...duckdb'` therefore **requires `(READ_ONLY)`**; plain ATTACH fails (DuckDB does not know `gh://` is remote — see `todo/duckdb.md` item 1).
- Globbing (`GlobFilesExtended`): a pattern containing `**` does one `GET /git/trees/{sha}?recursive=1` (plus one `/contents/{parent}` call to find the subtree SHA when the pattern is not rooted) and filters client-side; single-level wildcards (`*`, `?`, `[`) do a BFS with one `/contents/{dir}` call per directory. The `truncated` flag of the Trees API (100k entries / 7 MB) is **not checked** — very large trees silently return a partial list.
- Rate-limit handling: 403/429 with a "rate limit" message throws `GitHub API rate limit exceeded. ... Rate limit resets at HH:MM:SS.` (from `x-ratelimit-reset`). No automatic backoff/retry.
- HTTP logging: `CALL enable_logging('HTTP'); ... SELECT * FROM duckdb_logs() WHERE type='HTTP'` shows one entry per API call.

### 1.2 Table functions

**`gh_repo(repo VARCHAR)`** — `'owner/repo'` for one repo, `'owner/*'` for every repo of an org/user (probes `/orgs/{owner}/repos?per_page=1`, falls back to `/users/{owner}/repos` on 404, paginates `per_page=100` until a short page). One `/repos/{o}/{r}` call per repo.

**`gh_repos(TABLE)`** — table in-out function; input must be a single VARCHAR column; each row is `'owner/repo'` or `'owner/*'`. Same columns as `gh_repo`.

Columns (23): `name VARCHAR, full_name VARCHAR, description VARCHAR, owner VARCHAR, private BOOLEAN, fork BOOLEAN, archived BOOLEAN, disabled BOOLEAN, visibility VARCHAR, default_branch VARCHAR, language VARCHAR, license VARCHAR, homepage VARCHAR, html_url VARCHAR, topics VARCHAR[], stargazers_count BIGINT, watchers_count BIGINT, forks_count BIGINT, open_issues_count BIGINT, size BIGINT, created_at TIMESTAMP, updated_at TIMESTAMP, pushed_at TIMESTAMP`.

**`gh_issues(repo VARCHAR, state := 'open'|'closed'|'all')`** — `GET /repos/{o}/{r}/issues?state=..&per_page=100&page=N`; rows with a `pull_request` key are skipped (so counts are lower than `api_count`). Stops when a page has < 100 items. A GitHub 422 (offset beyond its internal cap) is rethrown as `gh_issues: GitHub REST API pagination limit reached ... use state='open' or state='closed' instead of 'all'`.

Columns (15): `number BIGINT, title VARCHAR, state VARCHAR, state_reason VARCHAR, body VARCHAR, user VARCHAR (login), labels VARCHAR[], assignees VARCHAR[], milestone VARCHAR, locked BOOLEAN, comments BIGINT, created_at TIMESTAMP, updated_at TIMESTAMP, closed_at TIMESTAMP, html_url VARCHAR`.

**`gh_prs(repo VARCHAR, state := 'open'|'closed'|'all')`** `[DISCREPANCY: not in README at all]` — `GET /repos/{o}/{r}/pulls`, same pagination and 422 handling.

Columns (22): `number BIGINT, title VARCHAR, state VARCHAR, draft BOOLEAN, body VARCHAR, user VARCHAR, author_association VARCHAR, labels VARCHAR[], assignees VARCHAR[], reviewers VARCHAR[] (requested_reviewers), milestone VARCHAR, head_ref VARCHAR, head_sha VARCHAR, head_repo VARCHAR, base_ref VARCHAR, base_sha VARCHAR, locked BOOLEAN, created_at TIMESTAMP, updated_at TIMESTAMP, closed_at TIMESTAMP, merged_at TIMESTAMP, html_url VARCHAR`.

The only named parameter anywhere in `gh` is `state` (on `gh_issues` and `gh_prs`). There is no `token`, `per_page`, `since`, `labels` or `sort` parameter.

### 1.3 Auth

```sql
CREATE SECRET my_github_token (TYPE github, TOKEN 'github_pat_...');   -- provider 'config' (only one), named param: token
```
`GetToken()` order: (1) secret lookup `LookupSecret(tx, "gh://", "github")` — a secret with no `SCOPE` defaults to scope `gh://`; (2) env `GITHUB_TOKEN`. Sent as `Authorization: Bearer`. Unauthenticated: 60 req/h; token: 5,000 req/h; private repos need `repo` scope. Token is in `redact_keys`. No GitHub App / OAuth device flow support.

### 1.4 Limits
- Every directory listed and every file read is one REST call; globbing a deep tree without `**` burns one call per directory (the `todo/` notes propose GraphQL batching, not implemented).
- Issues/PRs: 100 per page, hard stop at GitHub's offset cap (~10k for `state='all'` on big repos).
- Org expansion: `per_page=100`, no cap besides rate limit.
- No caching across queries; the same `gh://` file read twice is fetched twice.

### 1.5 Runnable examples (from README, plus the source-only `gh_prs`)
```sql
SELECT * FROM read_csv('gh://duckdb/duckdb@main/data/csv/issue2934.csv') LIMIT 5;
SELECT count(*) FROM read_csv('gh://duckdb/duckdb@main/data/csv/glob/**/*.csv');
SELECT * FROM glob('gh://duckdb/duckdb@main/data/csv/*/*.csv');
SELECT name, stargazers_count, language FROM gh_repo('duckdb/*') ORDER BY stargazers_count DESC;
SELECT name, stargazers_count FROM gh_repos((VALUES ('duckdb/duckdb'), ('duckdb/pg_duckdb'), ('duckdb/duckdb-wasm')));
SELECT r.name, r.language FROM gh_repos((SELECT repo_name FROM my_repos)) r;
SELECT number, title, closed_at FROM gh_issues('duckdb/duckdb', state := 'closed') ORDER BY closed_at DESC;
SELECT state, count(*) FROM gh_issues('duckdb/duckdb', state := 'all') GROUP BY state;
SELECT number, user FROM gh_prs('duckdb/community-extensions', state := 'all') WHERE author_association IN ('MEMBER','OWNER');
ATTACH 'gh://duckdb/duckdb@main/test/sql/storage_version/storage_version.dbtest.duckdb' AS gh_db (READ_ONLY);
```

### 1.6 Gotchas
- `docs/README.md` and `docs/NEXT_README.md` are untouched extension-template boilerplate ("Quack") — ignore them.
- Reads only. Writes to `gh://` throw; there is no "create issue"/"comment" function.
- The ref-less form sends `ref=HEAD`; a repo with a branch literally named `HEAD` is an open TODO in the source.
- Requires OpenSSL via vcpkg at build time; CI is pinned to `v1.5-variegata` so binaries only load on DuckDB 1.5.x.
- All GitHub timestamps are parsed into naive `TIMESTAMP` (UTC).

---

## 2. `cloudfront` — signed-cookie auth for httpfs

**What it is for.** This extension does exactly one thing: at `CREATE SECRET ... TYPE cloudfront` time it signs a CloudFront *custom policy* with your RSA private key and stores the three resulting cookies (`CloudFront-Policy`, `CloudFront-Signature`, `CloudFront-Key-Pair-Id`) as a `Cookie:` header inside an ordinary **`http`-type** DuckDB secret. httpfs then attaches that header to every `https://<distribution>/...` request in scope, so `read_parquet('https://d111.cloudfront.net/data.parquet')` (or a Lambda/API behind CloudFront) works against a distribution that requires signed cookies. **It does not parse, list, or read CloudFront access logs**, does not touch the CloudFront API, and has no table functions. Its only scalar function is `cloudfront_version()` → `'cloudfront v0.1.0'`. (The `CLAUDE.md` in the repo is the original design prompt for this feature.)

**Can it read CloudFront access logs?** Not by itself. Standard/real-time CloudFront logs land in S3 (or Kinesis); you read them with core `httpfs`/`aws` (`read_csv('s3://bucket/prefix/*.gz', delim='\t', skip=2, ...)`) — nothing in this extension helps. It only helps if the *logs themselves* are served through a signed-cookie-protected CloudFront distribution, in which case any DuckDB reader over `https://` benefits.

**Install / load.**
```sql
INSTALL cloudfront FROM community;   -- README claims community availability
LOAD cloudfront;
LOAD httpfs;                          -- NOT auto-loaded; required for the secret to have any effect
```

### 2.1 Secret type and parameters (from `LoadInternal`)

Secret type `cloudfront`, `default_provider = "config"`. Two `CreateSecretFunction`s, identical named parameters:

| Param | Type | provider `config` | provider `env` |
|---|---|---|---|
| `KEY_PAIR_ID` | VARCHAR | required | optional; else env `CLOUDFRONT_KEY_PAIR_ID` (required) |
| `PRIVATE_KEY` | VARCHAR | one of the two required (PEM text) | optional; else env `CLOUDFRONT_PRIVATE_KEY` |
| `PRIVATE_KEY_PATH` | VARCHAR | one of the two required | optional; else env `CLOUDFRONT_PRIVATE_KEY_PATH` |
| `RESOURCE_PATTERN` | VARCHAR | default `*` | else env `CLOUDFRONT_RESOURCE_PATTERN` |
| `EXPIRATION_HOURS` | BIGINT | default `24` | else env `CLOUDFRONT_EXPIRATION_HOURS` |
| `SCOPE` | (standard) | **required**, must start with `https://` | same |

```sql
CREATE SECRET cf_auth (TYPE cloudfront, KEY_PAIR_ID 'K2JCJMDEHXQW5F', PRIVATE_KEY_PATH '/path/key.pem', SCOPE 'https://d111111abcdef8.cloudfront.net/');
CREATE SECRET cf_auth (TYPE cloudfront, KEY_PAIR_ID 'K2...', PRIVATE_KEY (SELECT content FROM read_text('key.pem')), SCOPE 'https://.../');
CREATE SECRET cf_auth (TYPE cloudfront, PROVIDER env, SCOPE 'https://d111111abcdef8.cloudfront.net/');
CREATE SECRET cf_auth (TYPE cloudfront, KEY_PAIR_ID 'K2...', PRIVATE_KEY_PATH 'key.pem', SCOPE 'https://.../', RESOURCE_PATTERN 'api/*', EXPIRATION_HOURS 48);
```

What gets signed (`GenerateSignedCookiesWithKey`): policy `{"Statement":[{"Resource":"https://<host-from-SCOPE>/<RESOURCE_PATTERN>","Condition":{"DateLessThan":{"AWS:EpochTime":<now+EXPIRATION_HOURS>}}}]}`, RSA-SHA1 (`EVP_sha1`) signature, CloudFront's URL-safe base64 (`+`→`-`, `=`→`_`, `/`→`~`). Only the **host** part of `SCOPE` goes into the policy; any path in `SCOPE` matters only for httpfs secret matching.

The stored secret is `KeyValueSecret(scope, "http", provider, name)` with `extra_http_headers = MAP{'Cookie': 'CloudFront-Policy=...; CloudFront-Signature=...; CloudFront-Key-Pair-Id=...'}`. Consequences (all confirmed by `test/sql/cloudfront_secret.test`):
- `SELECT type FROM duckdb_secrets() WHERE name='cf_auth'` returns **`http`**, not `cloudfront`. `duckdb_secret_types()` does list `cloudfront`.
- The cookie value is **not redacted**: `secret_string` shows the full policy/signature (README says so: "shows cookie values").
- Cookies are generated **once** at CREATE and never refreshed. After `EXPIRATION_HOURS` every request gets 403 until you `CREATE OR REPLACE SECRET`. Persistent secrets (`CREATE PERSISTENT SECRET`) therefore go stale on disk.

### 2.2 Auth/IAM
No AWS IAM at all — CloudFront signed cookies are validated by the distribution's trusted key group. You need: a CloudFront public key + key group, the distribution's cache behavior set to `trusted_key_groups`, and the matching RSA private key (PEM, `BEGIN PRIVATE KEY` or `BEGIN RSA PRIVATE KEY`). The README's Terraform block provisions S3 + OAC + key group + distribution end to end.

### 2.3 Limits / gotchas
- Needs `httpfs` loaded separately; without it the secret is created but unused.
- SHA1 is what CloudFront mandates; the extension links OpenSSL through vcpkg.
- `EXTRACT`ed domain must be `https://`; `http://` scope throws `SCOPE must start with https://`.
- Env provider explicit params override env vars; `TryGetEnv` tries the exact name then upper-case.
- CI builds against DuckDB `main` daily, plus scheduled builds on `v1.4`/`v1.5` branches (`scheduled-1.4.yml`, `scheduled-1.5.yml`) — binaries exist per DuckDB minor.
- Read-only by nature (it only adds a request header); no write path exists.
- There is no `cloudfront://` filesystem prefix and no log-parsing function. `[DISCREPANCY: none in README, but naming invites the wrong assumption]`

---

## 3. `cloudwatch` — CloudWatch Logs/Metrics/Alarms + X-Ray, read and write

**What it is for.** A native (no AWS SDK, own SigV4 over DuckDB's bundled `duckdb_httplib_openssl`) extension that turns CloudWatch into DuckDB tables: `read_cloudwatch_logs` (FilterLogEvents → the 18-column OTLP log schema shared with `duckdb-otlp`), `read_cloudwatch_logs_insights` (server-side aggregation via StartQuery/GetQueryResults), `read_cloudwatch_metrics` (GetMetricData → 17-column OTLP gauge schema), `read_cloudwatch_service_dependencies` (X-Ray GetServiceGraph edges), a read-only `ATTACH 'cloudwatch:'` catalog exposing every log group as a table plus `alerts.open` (DescribeAlarms) and `service_map.dependencies`, **write** functions (`send_cloudwatch_logs` → PutLogEvents, `send_cloudwatch_metrics` → PutMetricData), idempotent log-group admin functions, and `cloudwatch_serve`, an in-process CloudWatch Logs/Metrics endpoint that can act as a real sink for the CloudWatch Agent. **There is no traces table**: the extension has no X-Ray `GetTraceSummaries`/`BatchGetTraces` path; "service_map" is a directed-edge dependency table, not spans.

**Install / load.**
```sql
INSTALL aws; LOAD aws;        -- aws depends on httpfs; httpfs registers the aws/s3 secret types
LOAD cloudwatch;              -- README shows LOAD only; built for DuckDB v1.5.5 (README: "A native DuckDB 1.5.5 extension")
CREATE SECRET cw_prod (TYPE aws, PROVIDER credential_chain, REGION 'eu-west-1');
```
`cloudwatch` itself registers **no secret type** and auto-loads nothing; it *consumes* an existing `aws` or `s3` secret (`cloudwatch_secret.cpp`: reads `key_id`, `secret`, `session_token`, `region`). Static keys also work: `CREATE SECRET (TYPE aws, KEY_ID '...', SECRET '...', REGION 'us-east-1')`. Without any secret: `No AWS credentials found. Load DuckDB's aws extension and create a secret...`.

### 3.1 Auth and region resolution (`GetCloudwatchCredentials`)
1. `secret => 'name'` (must be type `aws` or `s3`, else BinderException); otherwise exactly one `aws` secret, else exactly one `s3` secret; >1 of a type → `Found N secrets of type "aws"; name the one to use with the SECRET parameter`.
2. Region: `region =>` param → secret `REGION` → setting `s3_region` → env `AWS_REGION` → `AWS_DEFAULT_REGION` → error.
3. Endpoints: `logs.<region>.amazonaws.com`, `monitoring.<region>.amazonaws.com`, `xray.<region>.amazonaws.com` (`.amazonaws.com.cn` for `cn-*`). Plain `http://` endpoints are accepted only on loopback. Redirects are never followed.
4. Requests are SigV4-signed; ATTACH pins the secret *name* and re-resolves credentials at each table bind (so credential_chain refresh works).

IAM actions by surface: `logs:FilterLogEvents` (read logs / catalog tables), `logs:DescribeLogGroups` (ATTACH without `LOG_GROUPS`), `logs:Unmask` (`unmask => true`), `logs:StartQuery` + `logs:GetQueryResults` + `logs:StopQuery` (Insights), `cloudwatch:GetMetricData` (read metrics), `cloudwatch:DescribeAlarms` (`alerts.open`), `xray:GetServiceGraph` (service map), `logs:PutLogEvents` (send logs), `cloudwatch:PutMetricData` (send metrics), `logs:CreateLogGroup` / `logs:CreateLogStream` / `logs:PutRetentionPolicy` / `logs:DeleteLogGroup` (admin).

### 3.2 Time-range syntax (shared `ParseCloudwatchTime`, used by logs, insights, catalog)
`'now'`; relative `-<n><unit>` with unit **`s`, `m`, `h`, `d`, `w`** (`[DISCREPANCY: README lists only -2h/-7d examples; weeks also accepted]`); epoch **milliseconds** as a bare integer; ISO-8601 (with or without offset; naive = UTC). `start_time` must be `<= end_time`. `read_cloudwatch_metrics` has its own `ParseTime` that accepts only `s/m/h/d` (no `w`) and requires `start_time < end_time`. `read_cloudwatch_service_dependencies` has a third copy.

### 3.3 `read_cloudwatch_logs(log_group VARCHAR, ...)` — table function

First positional: a log-group **name** (sent as `logGroupName`) or **ARN** (sent as `logGroupIdentifier`). Named parameters (exact, from `logs_table.cpp`):

| Param | Type | Default | Validation |
|---|---|---|---|
| `filter` | VARCHAR | `''` | CloudWatch filter-pattern syntax (substring, `?term`, `{ $.json = ... }`, `[w1, w2]`) |
| `start_time` | VARCHAR | `'-15m'` | see 3.2 |
| `end_time` | VARCHAR | `'now'` | |
| `log_stream_prefix` | VARCHAR | `''` | mutually exclusive with `log_streams` |
| `log_streams` | VARCHAR[] | `[]` | ≤ 100 exact stream names, no empties |
| `order` | VARCHAR | `'desc'` | `asc`/`desc`; quote it: `"order" => 'asc'` (reserved word) |
| `page_size` | BIGINT | `10000` | 1–10000 (`limit` on FilterLogEvents) |
| `max_rows` | BIGINT | `0` | 0 = unlimited safety cap |
| `retries` | BIGINT | `4` | 0–100; exponential 1,2,4,…,60 s, interrupt-checked every 100 ms |
| `timeout` | BIGINT | `60` | seconds, ≥ 1 |
| `unmask` | BOOLEAN | `false` | needs `logs:Unmask` |
| `secret` | VARCHAR | inferred | |
| `region` | VARCHAR | inferred | |
| `endpoint` | VARCHAR | AWS | origin only (no path/query); http only on loopback |

Streams pages into DuckDB (single-threaded scan, projection pushdown). Follows `nextToken` until AWS omits it, it stops changing, or `max_rows` is hit; AWS pages are ≤ 10k events / 1 MiB.

**Return schema (18 columns, OTLP logs shape):**

| # | Column | Type | Populated from |
|---|---|---|---|
| 1 | `time_unix_nano` | TIMESTAMP_NS | event `timestamp` |
| 2 | `observed_time_unix_nano` | TIMESTAMP_NS | event `ingestionTime` |
| 3 | `trace_id` | VARCHAR | NULL |
| 4 | `span_id` | VARCHAR | NULL |
| 5 | `service_name` | VARCHAR | NULL |
| 6 | `service_namespace` | VARCHAR | NULL |
| 7 | `service_instance_id` | VARCHAR | NULL |
| 8 | `severity_number` | INTEGER | NULL |
| 9 | `severity_text` | VARCHAR | NULL |
| 10 | `event_name` | VARCHAR | NULL |
| 11 | `body` | VARCHAR | `message`, verbatim |
| 12 | `resource_attributes` | VARCHAR (JSON) | `{"cloud.provider":"aws","cloud.region":..,"aws.log.group.names":..,"aws.log.stream.names":..}` |
| 13 | `scope_name` | VARCHAR | NULL |
| 14 | `scope_version` | VARCHAR | NULL |
| 15 | `scope_attributes` | VARCHAR | NULL |
| 16 | `log_attributes` | VARCHAR (JSON) | `{"aws.cloudwatch.log.event_id": eventId}` |
| 17 | `dropped_attributes_count` | INTEGER | NULL |
| 18 | `flags` | INTEGER | NULL |

The extension deliberately never infers severity/service/trace from the message; parse `body` with `json_extract` yourself. FilterLogEvents returns the *original* event (log transformations are not applied) — use Insights for transformed fields.

### 3.4 `read_cloudwatch_logs_insights(query VARCHAR, ...)`

| Param | Type | Default | Notes |
|---|---|---|---|
| `log_groups` | VARCHAR[] | — | 1–50 names/ARNs (AWS cap on StartQuery), required unless `log_group` given |
| `log_group` | VARCHAR | — | single group; combines with `log_groups` |
| `start_time` / `end_time` | VARCHAR | `-15m` / `now` | |
| `max_rows` **or** `"limit"` | BIGINT | `0` | 0 → AWS default 1000; max 10000 |
| `max_wait` | BIGINT | `300` | seconds ≥ 1; on timeout/interrupt `StopQuery` is issued |
| `poll_interval_ms` | BIGINT | `500` | GetQueryResults polling |
| `secret`, `region`, `endpoint`, `retries`, `timeout` | | | as above |

Schema is **dynamic**: the query runs at bind time; columns = field names AWS returns, first-seen order, **all `VARCHAR`** (cast aggregates). Empty result → single `@message` column. Only throttling / `LimitExceededException` (concurrent-query cap) responses are retried, because Insights bills per byte scanned. `count_distinct` is approximate above ~10k.

### 3.5 `read_cloudwatch_metrics(namespace VARCHAR, metric_name VARCHAR, ...)` `[DISCREPANCY: README never documents this function; it is only mentioned as "the 17-column gauge shape read_cloudwatch_metrics returns"]`

Wraps `GetMetricData` (query protocol) with a single `MetricStat` query id `m1`.

| Param | Type | Default | Notes |
|---|---|---|---|
| `dimensions` | MAP(VARCHAR,VARCHAR) | `{}` | ≤ 30 entries, non-empty keys/values |
| `statistic` | VARCHAR | `'Average'` | `SampleCount/Average/Sum/Minimum/Maximum`, `pNN`, `tmNN`, `tsNN`, `tcNN`, `wmNN`, `IQM`, `PR` |
| `period` | BIGINT | `300` | seconds > 0 |
| `unit` | VARCHAR | `''` | CloudWatch unit enum, passed through |
| `start_time` / `end_time` | VARCHAR | `-15m` / `now` | `s/m/h/d` relative, `now`, or ISO; **no epoch-ms, no `w`** |
| `order` | VARCHAR | `'desc'` | → `ScanBy` TimestampDescending/Ascending |
| `max_datapoints` | BIGINT | `100800` | `MaxDatapoints` per request (AWS max) |
| `max_rows` | BIGINT | `0` | client cap |
| `retries` / `timeout` / `secret` / `region` / `endpoint` | | | as above (`endpoint` here is the *monitoring* origin) |

Terminal `PartialData` with no `NextToken`, `Forbidden`, `InternalError` → IOException.

**Return schema (17 columns, OTLP gauge shape):** `time_unix_nano TIMESTAMP_NS` (datapoint ts), `start_time_unix_nano TIMESTAMP_NS` (NULL), `name VARCHAR` (= metric_name), `description VARCHAR` (NULL), `unit VARCHAR` (= `unit` param or NULL), `int_value BIGINT` (NULL), `double_value DOUBLE` (value), `service_name / service_namespace / service_instance_id VARCHAR` (only if `dimensions` contains `service.name` / `service.namespace` / `service.instance.id`), `resource_attributes VARCHAR` (`{"cloud.provider":"aws","cloud.region":..}`), `scope_name / scope_version / scope_attributes VARCHAR` (NULL), `metric_attributes VARCHAR` (JSON: `namespace, statistic, period, query_id, label, status_code, messages, dimensions{}`), `flags INTEGER` (NULL), `exemplars_json VARCHAR` (NULL).

### 3.6 `read_cloudwatch_service_dependencies(...)` — no positional args
Named: `start_time` (default `-15m` in the function; catalog table defaults to last hour), `end_time` (`now`), `group_name`, `group_arn` (one or the other), `secret`, `region`, `xray_endpoint`, `retries`, `timeout`. Follows all `GetServiceGraph` pages before resolving edges.

Columns (17): `provider VARCHAR, source_service VARCHAR, target_service VARCHAR, source_type VARCHAR, target_type VARCHAR, edge_type VARCHAR, environment VARCHAR (NULL for AWS), window_start TIMESTAMP_NS, window_end TIMESTAMP_NS, request_count BIGINT, error_count BIGINT, fault_count BIGINT, throttle_count BIGINT, total_response_time_seconds DOUBLE, source_attributes VARCHAR (JSON), target_attributes VARCHAR (JSON), edge_attributes VARCHAR (JSON)`.

### 3.7 `ATTACH 'cloudwatch:' AS cw (TYPE cloudwatch, ...)` — read-only catalog

Path must be exactly `'cloudwatch:'`. Options (case-insensitive; `ORDER` must be quoted): `SECRET`, `LOG_GROUPS VARCHAR[]`, `REGION`, `ENDPOINT` (= `LOGS_ENDPOINT`), `LOGS_ENDPOINT`, `MONITORING_ENDPOINT`, `XRAY_ENDPOINT`, `FILTER`, `START_TIME`, `END_TIME`, `"ORDER"`, `PAGE_SIZE`, `MAX_ROWS`, `RETRIES`, `TIMEOUT`, `UNMASK BOOLEAN`, `SERVICE_MAP_START_TIME`, `SERVICE_MAP_END_TIME`, `XRAY_GROUP_NAME`, `XRAY_GROUP_ARN`.

Schemas: `logs` (one table per log group; names snapshotted at ATTACH — with `LOG_GROUPS` no network call, without it `DescribeLogGroups` is paged to completion), `alerts` (single table `open`), `service_map` (single table `dependencies`). DDL/DML rejected. Relative times are evaluated at scan time.

`cw.alerts.open` columns (15): `alarm_arn, alarm_name, alarm_type, status VARCHAR` (`StateValue`: `ALARM` or `INSUFFICIENT_DATA` only — two `DescribeAlarms` passes, `MaxRecords=100`, all of `MetricAlarm/CompositeAlarm/LogAlarm`), `state_transitioned_at TIMESTAMP, state_updated_at TIMESTAMP, description, reason, reason_data VARCHAR, actions_enabled BOOLEAN, alarm_actions VARCHAR[], namespace, metric_name, dimensions VARCHAR (JSON), configuration VARCHAR (JSON of the type-specific config)`. There is **no** table-function form for alarms — catalog only. `OK` alarms are never returned.

### 3.8 Write path

**`send_cloudwatch_logs(row ANY, log_group VARCHAR, log_stream VARCHAR [, secret VARCHAR [, endpoint VARCHAR]])`** → `'ok'` per row (NULL struct → NULL). `log_group`/`log_stream`/`secret`/`endpoint` must be **constants**. Mapping (first match wins): `body`/`message` → `message` (required, non-empty); `time_unix_nano`/`timestamp` → epoch ms (integer `time_unix_nano` = ns, integer `timestamp` = ms, temporal values converted exactly); `observed_time_unix_nano` fallback; else now. Everything else is dropped (no JSON envelope). Batches: ≤ 10,000 events, ≤ 1,048,576 bytes (message bytes + 26/event), ≤ 24 h span, stable-sorted by ts; no sequence tokens. Retries only pre-send transport errors and definite throttles; any `rejectedLogEventsInfo` → error (earlier batches may already be stored). Group and stream **must exist**.

**`send_cloudwatch_metrics(row ANY, namespace VARCHAR [, secret VARCHAR [, endpoint VARCHAR]])`** → `'ok'`. Mapping: `name`/`metric_name` → `MetricName`; `double_value`/`value` → `Value` (NULL skipped); `time_unix_nano`/`timestamp` → `Timestamp` (seconds; AWS rejects > 2 weeks old or > 2 h future); `unit` translated (`s/ms/us`→Seconds/Milliseconds/Microseconds, `By`→Bytes, `%`→Percent, `{x}`→Count, `ns` and unknown → `None`); `service_name` → dimension `service.name`; `metric_attributes`/`attributes` (JSON object of strings) → further dimensions. ≤ 1000 datums / < 1 MB per PutMetricData; not idempotent, only pre-work rejections retried. Cost warning from README: each namespace+name+dimension combo is a billed custom metric that cannot be deleted (ages out after 15 months).

**Admin (all VOLATILE, idempotent, secret/endpoint constant, other args per-row):**
`create_cloudwatch_log_group(name [, secret [, endpoint]])` → `'created'|'exists'`; `create_cloudwatch_log_stream(group, stream [, secret [, endpoint]])` → `'created'|'exists'`; `put_cloudwatch_retention_policy(group, days BIGINT [, secret [, endpoint]])` → `'ok'` (days validated against the CloudWatch list 1…3653 before the call); `delete_cloudwatch_log_group(name [, secret [, endpoint]])` → `'deleted'|'absent'`.

### 3.9 `cloudwatch_serve([uri VARCHAR [, options STRUCT]])` / `cloudwatch_stop([uri])`
Default URI `cloudwatch:localhost:10519` (also `cloudwatch://host:port`); returns the `http://host:port` URL to pass as `endpoint =>`. Options struct keys accepted by the validator: `schema_name, table_name (default cloudwatch_logs), groups_table_name (cloudwatch_log_groups), allow_other_hostname, create_table, auto_create_groups, max_body_bytes, http_threads`. `[DISCREPANCY: README and `ParseOptions` both read `metrics_table_name`, but the `valid` option set in `cloudwatch_server.cpp` omits it, so passing `{'metrics_table_name': ...}` throws "Unsupported cloudwatch_serve option"; the default `cloudwatch_metric_data` is the only usable name.]` Implements Logs JSON-1.1 ops `CreateLogGroup, CreateLogStream, DeleteLogGroup, PutRetentionPolicy, DescribeLogGroups, DescribeLogStreams, PutLogEvents, FilterLogEvents` (substring filters only) and query-protocol `PutMetricData`, `GetMetricData` (Sum/Average/Maximum/Minimum/SampleCount, no metric math/percentiles/pagination). SigV4 accepted unverified; binding off-loopback needs `allow_other_hostname`. Tables: `cloudwatch_logs(log_group, log_stream, timestamp_ms, ingestion_time_ms, event_id, message)`, `cloudwatch_log_groups`, `cloudwatch_metric_data(namespace, metric_name, timestamp_ms, value, unit, dimensions MAP)`. Not available under Emscripten. Works as a real sink for the CloudWatch Agent via `logs.endpoint_override` (gzip bodies inflated by the extension).

### 3.10 Limits summary
- FilterLogEvents: 10k events / 1 MiB per page; 100 explicit streams; one log group per call (use Insights or `UNION ALL` for many); DuckDB-side scan is single-threaded.
- Insights: 50 log groups; 10k rows; billed per byte scanned; 300 s default wait.
- GetMetricData: one metric per call; 30 dimensions; 100,800 datapoints per request.
- DescribeAlarms: `MaxRecords=100`, paged; only ALARM / INSUFFICIENT_DATA states.
- Retries max 100, backoff capped at 60 s; timeouts ≥ 1 s; everything is HTTPS SigV4 (no proxies configurable beyond DuckDB's HTTPUtil in the WASM branch).
- Regions: anything with a `logs.<region>.amazonaws.com` endpoint; `cn-` handled; GovCloud follows the same pattern.

### 3.11 Runnable examples (README)
```sql
SELECT time_unix_nano, body, resource_attributes
FROM read_cloudwatch_logs('/aws/lambda/orders-api', filter => 'ERROR', start_time => '-1h', "order" => 'desc') LIMIT 100;

ATTACH 'cloudwatch:' AS cw (TYPE cloudwatch, SECRET 'cw_prod', LOG_GROUPS ['/aws/lambda/orders-api','/aws/lambda/payments-api']);
SELECT time_unix_nano, body FROM cw.logs."/aws/lambda/orders-api" LIMIT 100;
SELECT * FROM cw.alerts.open;
SELECT * FROM cw.service_map.dependencies;

SELECT service_name, CAST(events AS BIGINT) AS events
FROM read_cloudwatch_logs_insights('filter status_code = 2 | stats count(*) as events by service_name',
     log_groups => ['/app/checkout','/app/gateway'], start_time => '-1h', secret => 'cw_prod') ORDER BY events DESC;

SELECT send_cloudwatch_logs(l, '/app/orders', 'duckdb-import', 'cw_prod') FROM read_cloudwatch_logs('/archive/orders', start_time => '-1h') l;
SELECT send_cloudwatch_metrics(m, '/obsbench/run1', 'cw_prod') FROM my_metrics m;
SELECT log_group, create_cloudwatch_log_group(log_group, 'cw_prod') FROM (VALUES ('/app/checkout'), ('/app/gateway')) t(log_group);
SELECT cloudwatch_serve('cloudwatch:0.0.0.0:10519', {'allow_other_hostname': true});
SELECT * FROM read_cloudwatch_service_dependencies(start_time => '-15m', end_time => 'now', group_name => 'production', secret => 'cw_prod');
-- source-only (undocumented in README):
SELECT time_unix_nano, double_value FROM read_cloudwatch_metrics('AWS/Lambda', 'Errors',
     dimensions => MAP {'FunctionName': 'orders-api'}, statistic => 'Sum', period => 60, start_time => '-6h', secret => 'cw_prod');
```

### 3.12 Gotchas
- DuckDB **1.5.5** exact; `exclude_archs: wasm_mvp;wasm_eh;wasm_threads` (no OpenSSL SigV4 in browser builds).
- Needs `httpfs` + `aws` loaded for the secret types; `make test` runs offline only, real paths are `test/e2e/*.sh`.
- Reads *and* writes: `send_cloudwatch_logs`, `send_cloudwatch_metrics`, and `delete_cloudwatch_log_group` mutate your AWS account; `send_*` are non-idempotent and partially-applied on failure.
- `"order"` and `"limit"` must be double-quoted as named parameters.
- Timestamps come back as `TIMESTAMP_NS` (UTC); `alerts.open` uses plain `TIMESTAMP`.
- `read_cloudwatch_metrics` is undocumented in the README and has its own narrower time parser.

---

## 4. Feeding an observability / incident pipeline in DuckDB (with duck_hunt, Sentry, Slack)

1. **Ingest raw**: `read_cloudwatch_logs(group, start_time => '-1h')` or `ATTACH 'cloudwatch:'` per service; keep `body` verbatim and `resource_attributes->>'aws.log.stream.names'` as the instance key; persist to a local table/Parquet so re-queries don't re-hit FilterLogEvents.
2. **Parse with duck_hunt**: `parse_duck_hunt_log(body, 'auto')` (or a `regexp:`/config parser for the app's JSON) over that table to get structured `severity`, `error_code`, `file:line`, stack fingerprints — cloudwatch leaves `severity_*` NULL on purpose, duck_hunt fills it.
3. **Pre-aggregate in AWS when volume is high**: `read_cloudwatch_logs_insights('stats count(*) by @logStream, bin(5m)' ...)` and `read_cloudwatch_metrics('AWS/Lambda','Errors', statistic=>'Sum', period=>60)` for error-rate/throttle series without paying to pull every event.
4. **Alarm context**: `cw.alerts.open` joined on `metric_name`/`dimensions` to the parsed log spikes gives "which alarm, which stream, which stack" in one query; `service_map.dependencies` (`fault_count`, `error_count`) shows blast radius upstream/downstream.
5. **Correlate with Sentry**: pull Sentry issues/events via the Sentry MCP into a DuckDB table (issue id, fingerprint, first/last seen, release) and join on duck_hunt's exception fingerprint or `trace_id` extracted from `body` JSON; unmatched Sentry issues = untriaged, unmatched log fingerprints = not yet reported.
6. **Deploy correlation**: `gh_prs('org/repo', state:='all')` (`merged_at`, `head_sha`) and `read_json('gh://org/repo@main/deploy/manifest.json')` give the release timeline to bucket incidents by deploy; `gh_issues` links incidents to open tickets.
7. **Signed-cookie artefacts**: if runbooks/reference datasets sit behind a CloudFront distribution, one `TYPE cloudfront` secret lets the same DuckDB session `read_parquet('https://d111.cloudfront.net/...')` (CloudFront *access logs* still come from S3 via httpfs, not this extension).
8. **Write back**: `send_cloudwatch_metrics` publishes derived SLIs (e.g. duck_hunt error count per service, `unit=>'{error}'`→Count) so existing CloudWatch alarms can fire on them; `send_cloudwatch_logs` archives a triage summary stream.
9. **Notify**: the final `SELECT` (alarm, service, top fingerprint, Sentry link, suspect PR) is formatted in SQL and posted with the Slack MCP `slack_send_message`; a scheduled task re-runs the pipeline hourly.
10. **Local dev/CI**: `cloudwatch_serve` + `test/e2e/roundtrip.sh` pattern lets the whole pipeline run against a fake CloudWatch with no AWS credentials.

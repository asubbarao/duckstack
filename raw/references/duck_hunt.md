# duck_hunt — DuckDB community extension reference

Source of truth: clone of teaguesterling/duck_hunt at 68ca1c4 (docs/*.md, README.md, PARSERS.md, AGENTS.md, RELEASE_NOTES_v1.2.0.md, new-formats.md, and `src/`). Where docs and source disagree, **source wins**; every discrepancy is flagged with `[DISCREPANCY]`.

```sql
INSTALL duck_hunt FROM community;
LOAD duck_hunt;
```
Platforms: Linux x86_64/aarch64, macOS x86_64/arm64, WASM. **Windows unsupported** (MSVC `std::regex` complexity cap — `regex_error(error_complexity)` in several parsers).

---

## 1. Every exposed function (from `src/duck_hunt_extension.cpp` `LoadInternal`)

Registered, in order: `read_duck_hunt_log`, `parse_duck_hunt_log`, `read_duck_hunt_workflow_log`, `parse_duck_hunt_workflow_log`, `status_badge`, `duck_hunt_formats`, `duck_hunt_diagnose_parse`, `duck_hunt_diagnose_read`, `duck_hunt_detect_format`, table macro `duck_hunt_match_command_patterns`, `duck_hunt_load_parser_config`, `duck_hunt_unload_parser`.

**There is no `read_test_results`, `read_duckdb_test`, `parse_test_results`, `*_each` or `*_lateral` function.** DuckDB sqllogictest / unittest output is handled by `format := 'duckdb_test'` inside `read_duck_hunt_log`/`parse_duck_hunt_log`. LATERAL is supported by the *same* two log functions (they are registered as DuckDB in-out table functions), not by separate variants.

### 1.1 `read_duck_hunt_log(source [, format]) ` — table function (in-out; LATERAL-capable)

Two overloads (`TableFunctionSet`): `(VARCHAR)` and `(VARCHAR, VARCHAR)`. Both have `in_out_function = ReadDuckHuntLogInOutFunction` (the plain-scan `ReadDuckHuntLogInitGlobal`/`ProcessMultipleFiles` code in the file is **dead**: the registered function pointer is `nullptr`).

| Positional | Type | Meaning |
|---|---|---|
| `source` | VARCHAR | File path, glob (`*`,`?`,`[`,`{`), directory ending in `/` (globs `*.xml,*.json,*.txt,*.log,*.out`), `/dev/stdin`, `zip://…`, `s3://`/`http(s)://` (any DuckDB FS), `.gz`/`.zst` (auto-decompressed by extension). If the path cannot be opened the string itself is treated as literal content (only in the dead path; in the live in-out path an unopenable single path yields **0 rows silently**). |
| `format` | VARCHAR | default `'auto'`. Accepts: exact format name, any alias, a format **group** (`'python'`, `'lint'`…), a comma-separated **chain** `'gcc_text,make_error'` (first that yields events wins; `auto`/`unknown` not allowed inside a chain), `'regexp:<pattern>'`, `'config:<path.json>'`, a bare `*.json` path or an `http(s)://…json` URL (treated as a custom-parser config file — footgun documented in `parse_content.cpp`). Unknown names raise `Unknown format: 'x'. Did you mean 'y'?` (edit-distance suggestion). |

Named parameters (identical on both overloads):

| Named param | Type | Default | Notes |
|---|---|---|---|
| `severity_threshold` | VARCHAR | `'all'` (== `'debug'`) | `'all'\|'debug'\|'info'\|'warning'\|'error'\|'critical'`. Event emitted iff `severity >= threshold`. **Any other string silently becomes `'warning'`** (`StringToSeverityLevel` default). Applied after parsing (post-filter), also in streaming mode. |
| `ignore_errors` | BOOLEAN | `false` | `[DISCREPANCY]` Parsed at bind but **never consulted in the live in-out execution path** (only in the dead `ProcessMultipleFiles`). In practice unreadable files are always skipped silently (0 rows, no error) regardless of this flag; parser exceptions always propagate. |
| `content` | ANY | `'full'` | Controls `log_content`: integer N → truncate to N chars + `...`; `0` or negative or `'none'` → NULL; `'smart'` → keep ±2 lines around `log_line_start..log_line_end`, capped at 200 chars (the internal `content_limit` default; not settable together with `'smart'`); `'full'` → untouched. Other strings → `BinderException: Invalid content mode`. |
| `context` | INTEGER | `0` | N surrounding log lines. `>0` **adds a 40th column `context`** of type `LIST(STRUCT(line_number INTEGER, content VARCHAR, is_event BOOLEAN))`. Capped at 50 (silently). Negative → BinderException. `context > 0` disables streaming (whole file is read). NULL for events with no `log_line_start` (e.g. JSON formats). |
| `include_unparsed` | BOOLEAN | `false` | **Undocumented.** `regexp:` format only: emits one extra row per non-matching line with `event_type='unknown'`, `status`/`severity` NULL, `message` empty, `log_content` = the line, `log_line_start/end` set, `category='regexp_match'`. |

Return columns: the 39-column Schema V2 (section 2) + optional `context`.

Execution model (`ReadDuckHuntLogInOutFunction`):
* Glob source → **batch** over every matched file: each file read fully (100 MB cap → `InvalidInputException "exceeds maximum size limit"`), format auto-detected per file from full content, `log_file` set per event, unreadable files skipped.
* Single file → 8 KB **sniff** (`SNIFF_BUFFER_SIZE = 8192`) for auto-detect; if the parser `supportsStreaming()` and format is not `regexp:` and `context = 0`, the file is **streamed** line-by-line via `LineReader` (`parseLine`), otherwise read whole (100 MB cap) and parsed via `ParseFile` (lets XML parsers use webbed's `read_xml` on the path). Only **`jsonl`, `generic_lint`, `syslog`, `unity_editor` and JSON-config custom parsers** declare `supportsStreaming()`; every other format is batch.
* Fingerprint/pattern post-processing (`ProcessErrorPatterns`) runs in batch mode only; in streaming mode `fingerprint`, `pattern_id`, `similarity_score` come out NULL.
* `log_file` is set to the path only if the event has none already.

### 1.2 `parse_duck_hunt_log(text [, format])` — table function (in-out; LATERAL-capable)

Same overloads, same named params (`severity_threshold`, `ignore_errors` [no-op], `content`, `context`, `include_unparsed`), same 39(+1) columns. `text` is always literal content; never a path. `log_file` is NULL. Context key is `""`. Parser exceptions are wrapped: `InvalidInputException: duck_hunt: parser for format 'X' failed on the provided content: …`. Empty string → 0 rows.

### 1.3 `read_duck_hunt_workflow_log(source [, format])` — table function (plain scan, **not** LATERAL)

Overloads `(VARCHAR)`, `(VARCHAR, VARCHAR)`. Named params: `severity_threshold` VARCHAR (default all), `ignore_errors` BOOLEAN (accepted, unused). **No** `content`/`context`.

`format` values (case-insensitive, `StringToWorkflowLogFormat`): `'auto'`, `'github_actions'`|`'github'`, `'gitlab_ci'`|`'gitlab'`, `'jenkins'`, `'docker_build'`|`'docker'`, `'spack'`|`'spack_build'`, `'github_actions_zip'`. Anything else → `BinderException "Unknown workflow format… Supported: github_actions, gitlab_ci, jenkins, docker_build."` (message omits spack/zip).

Source handling: if `source` contains `://` (e.g. `zip://run.zip/0_Build.txt`) it is read directly; else `FileExists` → read (compression auto-detected), otherwise **the string is treated as inline content**. No glob support. `github_actions_zip` requires `INSTALL zipfs FROM community; LOAD zipfs;` and reads `{N}_{job}.txt` members, filling `job_order`/`job_name`.

Auto-detect order (`DetectWorkflowLogFormat`, first match wins): GitHub Actions (`##[group]`, `##[endgroup]`, `::group::`, `::endgroup::`, `Run actions/`) → GitLab (`Running with gitlab-runner`, `Preparing the "docker"`, `$ docker run`+`gitlab`, `Job succeeded`+`Pipeline #`) → Jenkins (`Started by user`, `Building in workspace`, `Finished: SUCCESS|FAILURE`, `[Pipeline]`) → Docker (`Step ` + `/`, `Sending build context to Docker daemon`, `Successfully built|tagged`, `COPY --from=`) → Spack (`==> ` + (`Executing phase:`|`spack-stage`|`spack/opt/spack`)).

Return columns (44): the Schema V2 columns **minus `log_file`** (38), then `workflow_type VARCHAR`, `hierarchy_level INTEGER`, `parent_id VARCHAR`, `job_order INTEGER` (NULL unless zip), `job_name VARCHAR` (NULL unless zip). `[DISCREPANCY]` docs/schema.md says workflow output is "standard schema plus" extras; in fact `log_file` is absent.

### 1.4 `parse_duck_hunt_workflow_log(text [, format])` — table function (plain scan)

Overloads `(VARCHAR)`, `(VARCHAR, VARCHAR)`. **No named parameters at all** (`[DISCREPANCY]` docs/index.md, README and workflow-formats.md list `severity_threshold` — it is not registered and would error). `format` accepts the workflow names above except `github_actions_zip`. Parsing happens **at bind time**; a parser exception is turned into one row with `tool_name='parse_duck_hunt_workflow_log'`, `message='Parse error: …'`, `status='ERROR'`, `workflow_type='error'`, `parent_id='parse_error'`. Return columns: 38 base (no `log_file`) + `workflow_type`, `hierarchy_level`, `parent_id` (41 columns; **no** `job_order`/`job_name`).

### 1.5 `duck_hunt_formats()` — table function, no args

Columns: `format VARCHAR`, `description VARCHAR`, `category VARCHAR`, `priority INTEGER`, `requires_extension VARCHAR` (NULL or `'webbed'`), `supports_workflow BOOLEAN` (true if category is `ci_system`/`workflow`/contains `ci`), `command_patterns LIST(STRUCT(pattern VARCHAR, pattern_type VARCHAR))` (`pattern_type` ∈ `literal|like|regexp`), `groups LIST(VARCHAR)`. First row is the meta format `auto` (category `meta`, priority 0). Sorted by category then format. Lists the 110 `read/parse_duck_hunt_log` parsers **plus** custom ones; the 6 workflow-engine formats are **not** listed (separate registry). `[DISCREPANCY]` docs/custom-parsers.md queries `format_name`; the real column is `format`. RELEASE_NOTES orders by `category, format` — correct.

### 1.6 `duck_hunt_diagnose_parse(content [, emit])` / `duck_hunt_diagnose_read(path [, emit])` — table functions

`emit` VARCHAR ∈ `'all'` (default) | `'valid'` | `'invalid'`, else BinderException. Columns: `format VARCHAR`, `priority INTEGER`, `can_parse BOOLEAN`, `events_produced BIGINT` (only computed when `can_parse`), `is_selected BOOLEAN` (what `auto` would pick). Sorted priority desc. Runs at bind. `diagnose_read` reads the whole file (100 MB cap, `..` path traversal rejected).

### 1.7 `duck_hunt_detect_format(content VARCHAR) → VARCHAR` — scalar

Same logic as `format := 'auto'` (8 KB sniff, priority-ordered). `[DISCREPANCY]` docs say returns `NULL` when nothing matches; **source returns the string `'unknown'`** (also for empty input). Never throws.

### 1.8 `status_badge` — scalar set (3 overloads)

| Overload | Result |
|---|---|
| `status_badge(status VARCHAR)` | case-insensitive: `ok\|pass\|passed\|success`→`[ OK ]`; `fail\|failed\|error`→`[FAIL]`; `warn\|warning`→`[WARN]`; `running\|pending\|in_progress`→`[ .. ]`; else `[ ?? ]` (so `'INFO'`, `'SKIP'` → `[ ?? ]`) |
| `status_badge(error_count BIGINT, warning_count BIGINT)` | errors>0→`[FAIL]`, warnings>0→`[WARN]`, else `[ OK ]` |
| `status_badge(error_count BIGINT, warning_count BIGINT, is_running BOOLEAN)` | running→`[ .. ]`, then as above |

### 1.9 `duck_hunt_load_parser_config(json VARCHAR) → VARCHAR` / `duck_hunt_unload_parser(name VARCHAR) → BOOLEAN` — scalars (fallible)

Load returns the registered format name; re-loading a custom name replaces it; built-in names → `InvalidInputException "Cannot replace built-in parser"`. Unload built-in → error; unknown → `false`. Registry is a **process-wide singleton** (not per-connection, despite docs saying "session-scoped").

### 1.10 `duck_hunt_match_command_patterns(cmd VARCHAR)` — table macro (undocumented)

Returns `format`, `priority`, `matched_patterns LIST(STRUCT(matched_pattern, pattern_type))` for every format whose `command_patterns` match `cmd` (literal `=`, `LIKE`, or `regexp_matches`). Used by workflow delegation.

---

## 2. Unified output schema (Schema V2, 39 columns, exact order)

| # | Column | Type | Meaning / population |
|---|---|---|---|
| 1 | `event_id` | BIGINT | 1-based per parse (per file in batch; per input row in LATERAL). Not globally unique. |
| 2 | `tool_name` | VARCHAR | e.g. `pytest`, `make`, `gcc`, `duckdb_test`, `regexp` (or `tool` capture group). |
| 3 | `event_type` | VARCHAR | **lowercase** in source (`ValidationEventTypeToString`): `test_result`, `lint_issue`, `type_error`, `security_finding`, `build_error`, `performance_issue`, `memory_error`, `memory_leak`, `thread_error`, `performance_metric`, `summary`, `debug_event`, `crash_signal`, `debug_info`, `unknown`. `[DISCREPANCY]` schema.md lists them UPPER_CASE (`TEST_RESULT`…); filter with lowercase, e.g. `event_type = 'summary'`. |
| 4 | `ref_file` | VARCHAR | Source file referenced (lint/compiler/test file). Empty string when absent (not NULL). |
| 5 | `ref_line` | INTEGER | Line in `ref_file`; NULL when -1. |
| 6 | `ref_column` | INTEGER | Column; NULL when -1. |
| 7 | `function_name` | VARCHAR | Empty string when the log names no function (gcc `In function`, mypy message, pytest/gotest test fn, junit, valgrind/gdb/strace, lcov, python_logging/log4j/logrus). Overloaded: eslint/sqlfluff/tflint rule id, trivy package, gcp/S3 API op, gradle task, gtest suite, rspec/mocha describe block, `duckdb_test` first 50 chars of the failing `SELECT`. Guard aggregations with `function_name != ''`. |
| 8 | `status` | VARCHAR | `PASS`, `FAIL`, `ERROR`, `WARNING`, `INFO`, `SKIP` (NULL only for `include_unparsed` rows). |
| 9 | `severity` | VARCHAR | `debug`, `info`, `warning`, `error`, `critical` (parsers may also emit `trace`/`warn`/`fatal`; threshold mapping treats `trace`→debug, `warn`→warning, `fatal`→critical, unknown/empty→warning). |
| 10 | `category` | VARCHAR | Domain classifier: `compilation`/`linking`, `test_failure`/`test_summary` (duckdb_test), HTTP method, syslog process, S3 bucket, stream (`stdout`/`stderr`), `regexp_match`, … |
| 11 | `error_code` | VARCHAR | Rule id (`E501`, `no-unused-vars`, mypy `[arg-type]`), compiler code (`C2065`), HTTP status, Windows event id, ASA code. |
| 12 | `message` | VARCHAR | Main text. |
| 13 | `suggestion` | VARCHAR | Fix hint (linters), mismatch details (duckdb_test). |
| 14 | `log_content` | VARCHAR | Raw log excerpt for the event; governed by `content` param; NULL when empty/`none`. |
| 15 | `structured_data` | VARCHAR | JSON extras (`{"passed":5,"failed":1}` on summaries; full k/v for firewall/S3/jsonl/logfmt) **or** the delegated format name for workflow delegation (`make_error`, `pytest_text`). |
| 16 | `log_line_start` | INTEGER | 1-indexed line in the log where the event starts; NULL for structured/JSON formats. |
| 17 | `log_line_end` | INTEGER | Last line of a multi-line event. |
| 18 | `log_file` | VARCHAR | Path parsed (set in `read_*`; NULL in `parse_*`). **Absent** in workflow functions. |
| 19 | `test_name` | VARCHAR | Full test id (`tests/test_x.py::TestA::test_b`, `TestSuite/subcase`). |
| 20 | `execution_time` | DOUBLE | `[DISCREPANCY]` schema.md/field_mappings say **milliseconds**; AGENTS.md says seconds; source passes through the tool's own number unchanged (pytest `duration` and gotest `Elapsed` are **seconds**: 0.123→0.123). 0.0 when unknown (not NULL). |
| 21 | `principal` | VARCHAR | ARN/email/user (cloud audit, S3 requester, windows user, VPC account id, Jenkins `Started by user`). NULL when empty. |
| 22 | `origin` | VARCHAR | Source IP/hostname/runner/workspace. NULL when empty. |
| 23 | `target` | VARCHAR | Destination IP:port / HTTP path / ARN. |
| 24 | `actor_type` | VARCHAR | `user`, `service`, `system`, `anonymous`. |
| 25 | `started_at` | VARCHAR | Timestamp string as found (ISO for CI/cloud). Not a TIMESTAMP — cast yourself. |
| 26 | `external_id` | VARCHAR | Request/trace id, commit SHA. |
| 27 | `scope` | VARCHAR | Level 1: workflow / cluster / account / suite / service / package (spack). |
| 28 | `scope_id` | VARCHAR | |
| 29 | `scope_status` | VARCHAR | |
| 30 | `group` | VARCHAR | Level 2: job / namespace / region / class / component. **Reserved word — write `"group"`.** |
| 31 | `group_id` | VARCHAR | |
| 32 | `group_status` | VARCHAR | |
| 33 | `unit` | VARCHAR | Level 3: step / pod / service / method / handler / spack phase. |
| 34 | `unit_id` | VARCHAR | |
| 35 | `unit_status` | VARCHAR | e.g. `success`, `failure`, `skipped` (lowercase, workflow parsers). |
| 36 | `subunit` | VARCHAR | Level 4: container / sub-resource. |
| 37 | `subunit_id` | VARCHAR | |
| 38 | `fingerprint` | VARCHAR | `<tool>_<category>_<hex(std::hash(tool:category:normalized_message))>`. Normalization replaces paths, timestamps, `:line:col:`, `line N`, hex addrs, 6+ digit ids, quoted tokens, decimals → `<decimal>`, integers → `<num>`, collapses whitespace. **`std::hash` is not stable across platforms/builds**; safe within one binary/run, don't persist across machines. |
| 39 | `similarity_score` | DOUBLE | Similarity (0–1) to the first message of the same `pattern_id`; NULL when 0.0. |
| 40 | `pattern_id` | BIGINT | Dense id (1,2,3…) assigned per query in first-seen order of `fingerprint`; NULL when -1 (streaming mode). Not stable across queries. |

All hierarchy/identity/temporal VARCHARs are NULL when empty; `ref_file`, `function_name`, `category`, `error_code`, `message`, `suggestion`, `structured_data`, `test_name`, `tool_name` are **empty strings** when empty.

### Severity levels & threshold
`debug(0) < info(1) < warning(2) < error(3) < critical(4)`; `'all'` = debug. Typical mapping: PASS→info, SKIP→warning, FAIL/ERROR→error, summaries→info (or warning when issues found), compiler warning→warning, security LOW/MEDIUM/HIGH/CRITICAL → info/warning/error/critical, app-log TRACE/DEBUG→debug, WARN→warning, FATAL→critical.

### Status vs severity
`status` is the semantic outcome; `severity` the importance. A passing test: `status='PASS', severity='info'`; skipped: `status='SKIP', severity='warning'`.

### Summary events
Many parsers append a `SUMMARY` row (`event_type='summary'`) with counts in `structured_data` (pytest, eslint, flake8, mypy, pylint; `duckdb_test` uses `event_type='test_result'`, `category='test_summary'`, `message='Test summary: N tests passed'`). `regexp:` with zero matches emits one `INFO` row `"No matches found for the provided pattern"` (`category='regexp_summary'`); an invalid regex emits one `ERROR` row `Invalid regex pattern '…'` (`category='parse_error'`) rather than throwing.

### Format auto-detection rules (`ParserRegistry::findParser`)
1. Only the first **8 KB** of content is examined (`MAX_DETECTION_SNIFF_SIZE = 8192`); for files, only the first 8 KB is even read.
2. Parsers are sorted by `priority` desc (VERY_HIGH=100, HIGH=80, MEDIUM=50, LOW=30, VERY_LOW=10), ties broken by **registration order** (tool_outputs → test_frameworks → build_systems → linting_tools → debugging → ci_systems → structured_logs → web_access → cloud_logs → app_logging → infrastructure → infrastructure_tools → coverage → distributed_systems).
3. All parsers whose `canParse()` is true **at the highest claiming priority** are candidates; lower-priority claimants ignored.
4. Among ties, the first candidate whose `parse(sniff)` yields ≥1 event wins; if none yields, the first by registration order.
5. Nothing matches → `read/parse` return 0 rows; `duck_hunt_detect_format` returns `'unknown'`.
6. Format groups (`'python'` etc.) use the same priority order but run `canParse` on the full content and take the first parser producing events.
7. Comma chains try each format in order (whole file re-read per attempt) and stop at the first non-empty result.
8. JSON-family parsers get `ExtractJsonSection` (skips leading non-JSON lines to the first line starting with `[`/`{`); XML-family get `ExtractXmlSection` (from `<?xml` or first start-of-line `<tag`). So `pytest --json-report-file=-` output with a banner still parses.

Practical consequences: `make` output containing `file:line:col: error:` diagnostics auto-detects as **`gcc_text`** (HIGH) not `make_error` (MEDIUM); `.py` file diagnostics are rejected by `gcc_text` so mypy wins; `generic_lint` (LOW) and `generic_error` (VERY_LOW) are fallbacks. Use `duck_hunt_diagnose_parse/read` to see the contest.

---

## 3. Supported formats by family (exact `format :=` strings, aliases, priority, maturity)

Maturity from docs/format-maturity.md: ★★★★★ Production (10+ tests), ★★★★ Stable (6+), ★★★ Beta, ★★ Alpha, ★ Experimental, `–` = not rated in that doc. Registry = 110 log parsers (`duck_hunt_formats()`), plus 6 workflow formats.

### Test frameworks (`read/parse_duck_hunt_log`)
| Format | Aliases | Prio | Groups | Maturity | Notes |
|---|---|---|---|---|---|
| `pytest_json` | – | 100 | python,test | ★★★ | `pytest --json-report`; `outcome` passed/failed/skipped/error; **xfailed/xpassed map to ERROR** (default branch). `execution_time` = `duration` or `call.duration` (seconds). Summary row from `summary` object. |
| `pytest_text` | `pytest` | 80 | python,test | ★★★ | detects `::` + PASSED/FAILED/SKIPPED; statuses PASS/FAIL/SKIP/ERROR; FAILURES section gives `ref_file`,`ref_line`,`message`. |
| `pytest_cov_text` | `pytest_cov`,`pytest-cov` | 80 | python,test,coverage | ★★★★★ | |
| `gotest_json` | `gotest`,`go_test`,`go_test_json` | 100 | go,test | ★★★★★ | `go test -json`; `Elapsed` seconds. |
| `gotest_text` | (`gotest` alias collides; use full name) | 80 | go,test | ★★★ | |
| `cargo_test_json` | `cargo_test` | 100 | rust,test | ★★★★ | |
| `junit_text` | `junit` | 80 | java,test | ★★★★★ | Maven Surefire/TestNG text |
| `junit_xml` | – | 100 | java,test | ★★★★ | **requires `webbed`** (`INSTALL webbed FROM community; LOAD webbed;`); detects `<testsuite`/`<testsuites`; works from string too (`parseWithContext` → `xml_to_json`). |
| `unity_test_xml` | – | 100 | unity,dotnet,test | – | requires webbed; NUnit 3 `<test-run testcasecount=`; docs: use `read_` not `parse_`. |
| `gtest_text` | `gtest`,`googletest` | 80 | c_cpp,test | ★★★ | `function_name` = suite name only if `[----------] N tests from Suite` header present. |
| `rspec_text` | `rspec` | 80 | ruby,test | ★★★ | |
| `mocha_chai_text` | `mocha`,`chai` | 80 | javascript,test | ★★★ | |
| `nunit_xunit_text` | `nunit`,`xunit` | 80 | dotnet,test | ★★★★★ | |
| `playwright_text` | `playwright` | 80 | javascript,test | – | undocumented in formats.md |
| `playwright_json` | – | 100 | javascript,test | – | undocumented in formats.md |
| `duckdb_test` | – | 80 | c_cpp,test | ★ Experimental | DuckDB `unittest` (Catch) output; see §6a. |

### Build systems / compilers
| Format | Aliases | Prio | Groups | Maturity |
|---|---|---|---|---|
| `gcc_text` | `gcc`,`g++`,`clang`,`clang++`,`cc`,`c++`,`gfortran`,`gnat`,`compiler_diagnostic` | 80 | c_cpp,fortran,build | – (tested in gcc_parser.test) |
| `make_error` | `make` | 50 | c_cpp,build | ★★★★ |
| `cmake_build` | `cmake` | 80 | c_cpp,build | ★★★★ (detects `CMake Error`, `CMake…Warning`, `-- Configuring incomplete`, `gmake[`) |
| `bazel_build` | `bazel` | 80 | c_cpp,java,build | ★★★ |
| `maven_build` | `maven`,`mvn` | 80 | java,build | ★★★ |
| `gradle_build` | `gradle` | 80 | java,build | ★★★ |
| `msbuild` | `visualstudio`,`vs` (enum aliases) | 80 | dotnet,build | ★★★ |
| `unity_editor` | `unity`,`unity_build` | 100 | csharp,gamedev,build | – |
| `cargo_build` | `cargo`,`rust` | 80 | rust,build | ★★★ |
| `node_build` | `node`,`npm`,`yarn` | 80 | javascript,build | ★★★ |
| `python_build` | `pip`,`setuptools` | 80 | python,build | ★★ Alpha |
| `docker_build` | `docker` | 80 | build,infrastructure | – (also a workflow format) |

### Linters / static analysis / formatters
Text: `pylint_text`(`pylint`,80,★★★), `mypy_text`(`mypy`,80,★★★), `flake8_text`(`flake8`,80,★★★), `black_text`(`black`,50,★★★), `yapf_text`(`yapf`,100,★★★★★), `clang_tidy_text`(`clang_tidy`,`clang-tidy`,80,★★★), `autopep8_text`(`autopep8`,80,★★★★★), `isort_text`(`isort`,80,★★★★), `bandit_text`(`bandit`,80,–), `ruff_text`(`ruff`,100,–), `ruff_json`(100,–), `eslint_text`(80,★★★), `rubocop_text`(80,★★★), `shellcheck_text`(80,★★★), `hadolint_text`(80,★★★), `generic_lint`(`lint`,30,★★★; `file:line:col: level: message`), `generic_error`(`error`,`fallback`,10,–; bare `error:`/`[ERROR]`/`[FAIL]` lines; undocumented).
JSON (all priority 100): `eslint_json`(`eslint`,★★★★), `stylelint_json`(`stylelint`,★★★★), `rubocop_json`(`rubocop`,★★★★), `swiftlint_json`(`swiftlint`,★★★★), `phpstan_json`(`phpstan`,★★★★), `shellcheck_json`(`shellcheck`,★★★★), `clippy_json`(`clippy`,★★★★), `markdownlint_json`(`markdownlint`,★★★★), `yamllint_json`(`yamllint`,★★★★), `spotbugs_json`(`spotbugs`,★★★★), `ktlint_json`(`ktlint`,★★★★), `hadolint_json`(`hadolint`,★★★★), `lintr_json`(`lintr`,★★★★), `sqlfluff_json`(`sqlfluff`,★★★★), `tflint_json`(`tflint`,★★★★), `kube_score_json`(`kubescore`,`kube_score`,★★★★).
Security JSON (100): `bandit_json`(`bandit`,★★★★), `trivy_json`(`trivy`,★★★), `tfsec_json`(`tfsec`,★★★).

### CI systems (flat parsers, `read_duck_hunt_log`)
`github_actions_text` (alias **`github_actions`**, 80, ★–; detects `::error::`/`::warning::`/`::notice::`/`::group::`/`##[group]`/`##[error]`…), `gitlab_ci_text` (`gitlab_ci`,`gitlab`, 80), `jenkins_text` (`jenkins`, 80), `drone_ci_text` (`drone`,`drone_ci`, 80, ★★★), `terraform_text` (`terraform`,`tf`, 80, ★★★), `github_cli` (`gh`, 80, ★★★; `gh run list` / `gh run view` / `gh run view --log` output), `ansible_text` (`ansible`, 80, ★★★).

### Workflow engines (`read_duck_hunt_workflow_log` / `parse_duck_hunt_workflow_log` only)
`github_actions` (`github`), `gitlab_ci` (`gitlab`), `jenkins`, `docker_build` (`docker`), `spack` (`spack_build`), `github_actions_zip` (read only; needs `zipfs`). Not maturity-rated. Hierarchy: scope=workflow/pipeline/package, group=job/stage, unit=step/phase; `hierarchy_level` 1–3, **4 = delegated** tool-parser event (`structured_data` = delegated format, `tool_name` from delegate). Delegation triggers on `##[group]Run <cmd>` (GHA), `+ cmd`/`$ cmd` (Jenkins/GitLab), `RUN cmd` (Docker), `==> [ts] 'cmd'` (Spack), matched via `command_patterns` (e.g. `make`→`make_error`, `pytest`→`pytest_text`, `flake8`, `mypy`, `eslint`→`eslint_json`, `cargo build|test`→`cargo_build`). Without delegation only "meaningful" lines are emitted (errors/warnings/status changes/`##[error|warning|notice]`).

### Debugging / coverage
`valgrind` (80, ★★★), `gdb_lldb` (`gdb`,`lldb`, 80, ★★★), `strace` (80, ★★★★★), `coverage_text` (`coverage`, 80, ★★★★★; coverage.py), `lcov` (`gcov`,`lcov_info`, 80, ★★★★★), `pytest_cov_text` (above).

### Application logging (all 80)
`python_logging` (`python_log`, ★★★★), `log4j` (`log4j2`,`log4j_text`,`logback`, ★★★★★), `logrus` (`logrus_text`, ★★★★★), `winston` (`winston_json`, ★★★), `pino` (`pino_json`, ★★★★), `bunyan` (`bunyan_json`, ★★★★★), `serilog` (`serilog_json`,`serilog_text`, ★★★★★), `nlog` (`nlog_text`, ★★★★★), `ruby_logger` (`ruby_log`, ★★★★), `rails_log` (`rails`, ★★★★★).

### Structured / generic logs
`jsonl` (`ndjson`,`json_lines`, prio 50, ★★★★★), `logfmt` (50, ★★★★★).

### Web / system logs (80)
`syslog` (★★★★★), `apache_access` (`apache`, ★★★), `apache_error` (`apache_err`, undocumented), `nginx_access` (`nginx`, ★★★).

### Cloud audit (80)
`aws_cloudtrail` (`cloudtrail`, ★★★★★), `gcp_cloud_logging` (`stackdriver`,`gcp_logging`, ★★★★★), `azure_activity` (`azure`,`azure_activity_log`, ★★★★★).

### Infrastructure / network / security (80)
`iptables` (`netfilter`,`ufw`, ★★★), `pf` (`pf_firewall`,`openbsd_pf`, ★★★★), `cisco_asa` (`asa`, ★★★), `vpc_flow` (`vpc_flow_log`,`vpc_flow_logs`,`aws_vpc_flow`, ★★★★), `kubernetes` (`k8s`,`kube`, ★★★★), `windows_event` (`windows`,`eventlog`,`windows_event_log`, ★★★), `auditd` (`audit`,`ssh_auth`, ★★★), `s3_access` (`s3_access_log`, ★★★★★).

### Distributed systems (80, all ★★★, loghub samples)
`hdfs` (`hadoop_hdfs`), `spark` (`apache_spark`), `android` (`logcat`,`android_logcat`), `zookeeper` (`zk`,`apache_zookeeper`), `openstack` (`nova`,`neutron`,`cinder`), `bgl` (`bluegene`,`blue_gene_l`).

### Meta / dynamic
`auto`; `regexp:<pattern>`; `<group name>`; `fmt1,fmt2`; `config:<path.json>` / `*.json` / `http(s)://…json` (custom parser config).

### Format groups (exact strings)
Language: `python`, `java`, `c_cpp`, `fortran`, `javascript`, `ruby`, `dotnet`, `rust`, `go`, `shell`, `docker`, `swift`, `php`, `mobile`, `csharp`, `unity`, `gamedev`. Tool-type: `lint`, `test`, `build`, `security`, `infrastructure`, `logging`, `cloud`, `ci`, `distributed`, `web`, `coverage`, `debug`, `custom` (config parsers).

### Names that look like formats but are NOT implemented
`[DISCREPANCY]` AGENTS.md lists `nunit_xml` and `checkstyle_xml`; they exist only in the enum/string map, no parser is registered → **accepted at bind, return 0 rows silently**. `new-formats.md` is a *proposal* — `k8s_logs`, `json_audit`, `firewall_logs`, `ssh_logs`, `auditd_logs`, `waf_logs`, `gcp_logs`, `structlog_json`, `loguru_text`, `winston_text`, `java_stacktrace`, `zap_json`, `zerolog_json`, `r_logger`, `r_futile_logger`, `gelf`, `cef`, `splunk_json`, `datadog_json`, `fluentd_json` are **not** formats (some landed under different names: `auditd`, `iptables`, `gcp_cloud_logging`, `winston`, `logrus`). PARSERS.md's `python_log`, `ruby_log`, `rails`, `ansible`, `coverage`, `docker` are aliases; `github_actions_text` is the flat parser, `github_actions` the workflow one (and an alias of the flat one in `read_duck_hunt_log`).

---

## 4. Every example from docs/examples.md (runnable; paths relative to repo root)

```sql
-- pytest JSON: per-test status and duration (seconds pass-through)
SELECT test_name, status, execution_time
FROM read_duck_hunt_log('test/samples/pytest.json', 'pytest_json');
-- → test_login_success PASS 0.123 | test_login_invalid_password FAIL 0.456 | test_create_user PASS 0.089

-- ESLint JSON: file/line/rule/message (error_code = ruleId)
SELECT ref_file, ref_line, error_code, message
FROM read_duck_hunt_log('test/samples/eslint.json', 'eslint_json');

-- GNU Make (explicit make_error also captures GCC lines + "make: *** [Makefile:23…] Error 1" with ref_file=Makefile, ref_line NULL)
SELECT ref_file, ref_line, severity, message
FROM read_duck_hunt_log('test/samples/make.out', 'make_error');

-- MyPy: trailing [code] → error_code, notes have empty error_code
SELECT ref_file, ref_line, error_code, message
FROM read_duck_hunt_log('test/samples/mypy.txt', 'mypy_text');

-- go test -json: Action pass/fail/skip → PASS/FAIL/SKIP, Elapsed → execution_time
SELECT test_name, status, execution_time
FROM read_duck_hunt_log('test/samples/gotest.json', 'gotest_json');

-- GitHub Actions workflow: unit = step name from ##[group]Run …, severity from npm WARN / ##[error]
SELECT unit, message, severity
FROM read_duck_hunt_workflow_log('test/samples/github_actions.log', 'github_actions')
WHERE length(message) > 0
LIMIT 5;

-- Status badges: ERROR→[FAIL], WARNING→[WARN], INFO→[ ?? ]
SELECT status_badge(status) AS badge, tool_name, ref_file, message
FROM read_duck_hunt_log('test/samples/make.out', 'make_error')
WHERE ref_file NOT LIKE '%Makefile%';

-- Aggregation by tool: total/errors/warnings
SELECT tool_name,
       COUNT(*) AS total,
       COUNT(*) FILTER (WHERE status = 'ERROR') AS errors,
       COUNT(*) FILTER (WHERE status = 'WARNING') AS warnings
FROM read_duck_hunt_log('test/samples/make.out', 'make_error')
GROUP BY tool_name;

-- Dynamic regexp parser on inline text: named groups severity/message map to columns; severity lowercased
SELECT severity, message
FROM parse_duck_hunt_log(
  'ERROR: Connection failed
   WARNING: Retrying in 5s
   ERROR: Max retries exceeded
   INFO: Shutting down',
  'regexp:(?P<severity>ERROR|WARNING|INFO):\s+(?P<message>.+)'
);

-- Context extraction: context := 2 adds a LIST(STRUCT(line_number, content, is_event)) column around each event
SELECT ref_file, message, context
FROM parse_duck_hunt_log(
  'Starting build process
Compiling main.c
src/main.c:15:5: error: ''ptr'' undeclared
Compilation failed
Build terminated',
  'make_error',
  context := 2
);

-- Access context elements (DuckDB lists are 1-indexed)
SELECT context[1].line_number, context[1].content
FROM parse_duck_hunt_log(log_text, 'make_error', context := 2);

-- Keep only the event's own lines from the context window
SELECT list_filter(context, x -> x.is_event) AS event_only
FROM read_duck_hunt_log('build.log', context := 3);

-- Size of the context window actually returned (clamped at file boundaries)
SELECT len(context) AS context_size
FROM read_duck_hunt_log('build.log', context := 5);

-- Quality gate: derive PASS/WARN/FAIL from counts
SELECT CASE
  WHEN COUNT(*) FILTER (WHERE status = 'ERROR') > 5 THEN 'FAIL'
  WHEN COUNT(*) FILTER (WHERE status = 'WARNING') > 20 THEN 'WARN'
  ELSE 'PASS'
END AS gate_status
FROM read_duck_hunt_log('build.log', 'auto');

-- Cluster errors by pattern_id: 24 raw issues → 5 distinct patterns (variable names normalized away)
SELECT pattern_id, COUNT(*) AS occurrences, ANY_VALUE(message) AS example_message
FROM read_duck_hunt_log('test/samples/large_build.out', 'make_error')
GROUP BY pattern_id
ORDER BY occurrences DESC;

-- Same, showing the fingerprint hash behind each pattern
SELECT pattern_id, COUNT(*) AS total, ANY_VALUE(fingerprint) AS fingerprint_sample
FROM read_duck_hunt_log('test/samples/large_build.out', 'make_error')
GROUP BY pattern_id;

-- Cross-run analysis over a glob: fingerprints recurring in >1 log file (log_file set per file)
SELECT fingerprint,
       COUNT(DISTINCT log_file) AS runs_affected,
       COUNT(*) AS total_occurrences,
       ANY_VALUE(message) AS example
FROM read_duck_hunt_log('logs/build-*.log', 'auto')
GROUP BY fingerprint
HAVING COUNT(DISTINCT log_file) > 1
ORDER BY runs_affected DESC;
```

Shell pipeline examples from the same doc:
```bash
# Real-time: parse make output from a pipe and print errors as markdown
make 2>&1 | duckdb -markdown -s "
  LOAD duck_hunt;
  SELECT status_badge(status) AS badge, ref_file, ref_line, message
  FROM read_duck_hunt_log('/dev/stdin', 'auto')
  WHERE status = 'ERROR'"

# JSON output for CI consumption: error counts per tool
./build.sh 2>&1 | duckdb -json -s "
  LOAD duck_hunt;
  SELECT tool_name, COUNT(*) AS errors
  FROM read_duck_hunt_log('/dev/stdin', 'auto')
  WHERE status = 'ERROR' GROUP BY tool_name"
```

Other doc examples worth keeping (formats.md / schema.md / custom-parsers.md / workflow-formats.md):
```sql
-- Detect a file's format via read_text (returns 'unknown', not NULL, when unmatched)
SELECT duck_hunt_detect_format(content) AS detected_format FROM read_text('build.log');

-- Format group: try every python parser in priority order
SELECT * FROM parse_duck_hunt_log(content, 'python');

-- Severity threshold: errors and critical only
SELECT * FROM read_duck_hunt_log('build.log', 'make_error', severity_threshold := 'error');

-- Keep summaries visible while filtering (note lowercase event_type)
SELECT event_type, status, message
FROM read_duck_hunt_log('pytest.json', 'pytest_json', severity_threshold := 'warning')
WHERE status = 'ERROR' OR event_type = 'summary';

-- Debug why auto picked what it picked
SELECT format, priority, can_parse, events_produced, is_selected
FROM duck_hunt_diagnose_read('mystery.log') WHERE can_parse;

-- Custom parser (session/process registry), then use by name and via auto/group
SELECT duck_hunt_load_parser_config('{
  "name": "simple_errors",
  "detection": {"contains": ["ERROR:", "WARN:"]},
  "patterns": [
    {"regex": "ERROR: (?P<message>.*)", "event_type": "BUILD_ERROR", "severity": "error"},
    {"regex": "WARN: (?P<message>.*)",  "event_type": "LINT_ISSUE",  "severity": "warning"}
  ]}');
SELECT severity, message FROM parse_duck_hunt_log('ERROR: disk full
WARN: low memory', 'simple_errors');
SELECT duck_hunt_unload_parser('simple_errors');

-- Inline config file as the format (not registered; no auto-detect)
SELECT * FROM parse_duck_hunt_log(content, 'config:parsers/my_format.json');

-- Workflow: failed steps
SELECT scope AS workflow, "group" AS job, unit AS step, unit_status, message
FROM read_duck_hunt_workflow_log('workflow.log', 'github_actions')
WHERE unit_status = 'failure';

-- Workflow delegation: compiler errors surfaced inside a CI log
SELECT ref_file, ref_line, message
FROM read_duck_hunt_workflow_log('jenkins.log', 'jenkins')
WHERE structured_data = 'make_error' AND severity = 'error';

-- GitHub Actions run ZIP (needs zipfs)
INSTALL zipfs FROM community; LOAD zipfs;
SELECT job_order, job_name, unit AS step, severity, message
FROM read_duck_hunt_workflow_log('workflow_run.zip', 'github_actions_zip')
WHERE severity = 'error';
SELECT * FROM read_duck_hunt_workflow_log('zip://workflow_run.zip/0_Build.txt', 'github_actions');
```

---

## 5. Gotchas

**Binding / constants**
* `read_duck_hunt_log` and `parse_duck_hunt_log` bind `format` and all named params at **bind time**; they must be constants. In a LATERAL the first positional can be a column reference and the second (format) a constant; the bind heuristics decide "is `input.inputs[0]` a format or a path?" via `IsValidFormat` — so **a single-argument call whose value is literally a format/group/alias name (e.g. `read_duck_hunt_log('python')`, `('test')`, `('make')`) also sets `format` to that name instead of `auto`** (the value is still used as the source path at execution).
* Format resolution goes through `StringToTestResultFormat` first; names in that map (`nunit_xml`, `checkstyle_xml`) bypass the "unknown format" check even though no parser exists → 0 rows. Names not in the map fall through to `IsValidFormat` (registry names, aliases, groups, chains, config paths) → BinderException with suggestion if invalid.
* `regexp:` with nothing after the colon → BinderException. Pattern supports `(?P<name>…)` and `(?<name>…)`; groups are rewritten to plain groups, so **don't mix numbered backreferences**. Recognised group names: `severity|level`, `message|msg|description|text`, `file|file_path|path|filename`, `line|line_number|lineno|line_num`, `column|col|ref_column|colno`, `code|error_code|rule|rule_id`, `category|type|class`, `test_name|test|name`, `suggestion|fix|hint`, `tool|tool_name`. Severity values `error|fatal|fail|failed`→ERROR, `warning|warn`→WARNING, `info|note|debug`→INFO, anything else → status WARNING with the raw text as `severity`; no severity group → WARNING/warning. Unmatched lines are skipped (unless `include_unparsed := true`). `ref_line` defaults to the *log* line number when no `line` group. Long lines are truncated by `SafeLineReader` (ReDoS guard); CRLF normalized.
* `parse_duck_hunt_workflow_log` has **no named params**; `read_duck_hunt_workflow_log` has only `severity_threshold`/`ignore_errors`.
* `severity_threshold` typos silently become `'warning'` (drops info/debug rows).
* `content := 'smart'` window is hard-capped at 200 chars.

**LATERAL joins** (`test/sql/lateral_join.test`)
* Works: `FROM t, LATERAL read_duck_hunt_log(t.path, 'gcc_text') e`, `LATERAL parse_duck_hunt_log(t.content) e`, `LEFT JOIN LATERAL … ON true`, with `regexp:` and `auto`, in CTEs/VALUES/UNION/window functions. NULL path/content → no rows (LEFT JOIN keeps the outer row).
* **Named parameters are not supported inside LATERAL** — DuckDB parses `severity_threshold := 'x'` there as a column reference. Use plain calls or filter in WHERE.
* The format can also come from a **column** as the 2nd argument (runtime `StringToTestResultFormat`), but that runtime path only handles enum-mapped names/aliases and `regexp:`; groups/chains/config paths passed via column are looked up as raw names.
* `read_duck_hunt_workflow_log`/`parse_duck_hunt_workflow_log` are **not** in-out functions: they cannot take a column as source in LATERAL (the bind takes `input.inputs[0].ToString()` — a column ref would be bound as a constant NULL/error).

**Files, stdin, strings, globs, readers**
* String vs file: `parse_duck_hunt_log(text)` = always literal; `read_duck_hunt_log(path)` = path (glob-expanded). For `read_duck_hunt_workflow_log`, a non-existent path is silently treated as literal content.
* stdin/pipe: `read_duck_hunt_log('/dev/stdin', 'auto')` (`make 2>&1 | duckdb -s "LOAD duck_hunt; FROM read_duck_hunt_log('/dev/stdin','auto')"`). Pipes cannot seek, so the whole stream is read in 64 KB chunks (100 MB cap); auto-detect on a pipe reads the first 8 KB then reads the rest. `/dev/null` → 0 rows.
* Globs: standard DuckDB `fs.GlobFiles` (`logs/**/*.log.gz` ok, remote `s3://…` globs ok). A path with glob chars is *never* treated as literal content. `regexp:` works with globs in the live path (`[DISCREPANCY]` formats.md says "multi-file glob patterns not supported with regexp"; that restriction lives only in the dead `ProcessMultipleFiles`). Directory path ending in `/` expands to `*.xml,*.json,*.txt,*.log,*.out` inside it. Paths containing `../` or `..\` are rejected (`Invalid file path`), max 4096 chars, no NUL.
* Missing file → **0 rows, never an error** (with or without `ignore_errors`).
* Compression: `.gz/.gzip` built-in; `.zst/.zstd` needs `LOAD parquet`. Compressed files are read in chunks (size unknown up front) and still subject to the 100 MB *decompressed* cap. Streaming works through the compressed handle.
* `read_text('f')` + `parse_duck_hunt_log(content, …)` is the way to combine with other readers (e.g. `SELECT e.* FROM read_text('logs/*.log') t, LATERAL parse_duck_hunt_log(t.content, 'auto') e`), and `duck_hunt_detect_format(content)` on `read_text` output classifies files without parsing. `parse_*` drops `log_file` — carry `t.filename` from `read_text` yourself. For persisting, `COPY (FROM read_duck_hunt_log('/dev/stdin','auto')) TO 'run.parquet'`.
* XML formats (`junit_xml`, `unity_test_xml`) call `webbed` (`xml_to_json`, `read_xml`) at runtime; without it → `InvalidInputException` "requires the 'webbed' extension". JUnit XML is detected by `<testsuite`; NUnit3 by `<test-run` + `testcasecount=`/`engine-version=`.
* Any `format` ending in `.json`, starting with `config:`, or an http(s) URL containing `.json` is fetched as a **custom parser config** (documented footgun GHSA-cvx3-3g3w-m22r item 4). Do not write `format := 'eslint.json'`.

**Streaming vs batch semantics**
* Single-file, `context = 0`, non-regexp, parser `supportsStreaming()` → streaming: `LIMIT` terminates early, order preserved, but `fingerprint`/`pattern_id`/`similarity_score` are NULL and multi-line events depend on the parser's `parseLine`. Add `context := 1` (or use a glob) to force batch mode when you need clustering.
* `event_id`/`pattern_id` restart per file (glob) and per input row (LATERAL) — don't use them as global keys; combine with `log_file`.

**Severity / status / filtering**
* `event_type` is lowercase; `status` is UPPERCASE; `severity` lowercase; `unit_status` lowercase (`failure`).
* Summaries: `status='INFO'` clean or `'WARNING'`/`'ERROR'` with issues; filter them out with `event_type <> 'summary'` (duckdb_test: `category <> 'test_summary'`).
* `execution_time` is 0.0, not NULL, when unknown; unit is whatever the tool emitted.
* `started_at` is VARCHAR.

**Log-line tracking**
* `log_line_start`/`log_line_end` are 1-indexed positions in the parsed text; NULL for JSON/XML formats; `ref_line` is the *source file* line. Context extraction relies on them. `regexp:` sets both to the matching line.

**Custom parsers (JSON config)**
* Required: `name`, `patterns[]` each with `regex` (Python-style named groups, JSON-escaped `\\`) and `event_type` ∈ `BUILD_ERROR|LINT_ISSUE|TEST_RESULT|TYPE_ERROR|SECURITY_FINDING|MEMORY_ERROR|UNKNOWN`. Optional: `aliases`, `priority` (default 50), `category` (default `tool_output`), `tool_name`, `groups` (default `["custom"]`), `description`, `detection` {`contains` any / `contains_all` / `regex`}. Pattern-level `severity`, `severity_map`, `status_map`. Groups mapped: `message|msg`, `severity|level`, `file|file_path|path`, `line|lineno|line_number`, `column|col`, `error_code|code|rule`, `function_name|func|function`, `test_name|test`, `scope`, `group`, `unit`. Registered parsers take part in `auto` and groups; inline `config:` ones don't.

**DuckDB version pinning**
* Repo submodules track branch **`v1.5-variegata`** for both `duckdb` and `extension-ci-tools`; CI (`MainDistributionPipeline.yml`) builds and publishes against **`duckdb_version: v1.5.4`** (wasm artifacts named `duck_hunt-v1.5.4-…`); a non-blocking canary builds against `main`. The code uses a `duckdb_compat.hpp` shim (`CompatBindNames`, `CompatSetOutputCardinality`, `CompatSetCreateInfoQualification`) and `#if __has_include("duckdb/common/column_index_map.hpp")` to detect v1.5+ glob API. Comments note DuckDB v2.0 enforces `SetFallible()` (only `duck_hunt_load_parser_config`/`duck_hunt_unload_parser` are marked). **For DuckDB 1.5.5**: community-extension binaries are built per DuckDB patch version; the repo pins 1.5.4, so `INSTALL duck_hunt FROM community` on 1.5.5 works only once the community repo has published a 1.5.5 build (otherwise build from source: `make release` with the submodule checked out at v1.5.5 — same v1.5 API line, so it should compile unchanged). No 1.5.5-specific code in the repo.
* `duck_hunt_version()` C symbol returns `DuckDB::LibraryVersion()` (the DuckDB it was built against).

**Misc discrepancies**
* docs/index.md / README signatures omit `include_unparsed` (exists) and show `parse_duck_hunt_workflow_log(text, format, severity_threshold)` (no such named param).
* README/PARSERS/format-maturity disagree on counts (110 / 106 / 105); registry has exactly 110 log parsers (24 tool_outputs + 14 test_frameworks + 12 build_systems + 15 linting + 4 debugging + 6 ci + 2 structured + 4 web + 3 cloud + 10 app_logging + 8 infrastructure + 1 ansible + 1 lcov + 6 distributed) + 6 workflow formats.
* AGENTS.md uses pre-V2 column names (`file_path`, `line_number`, `column_number`, `error_fingerprint`, `source_file`) — they no longer exist; use `ref_file`, `ref_line`, `ref_column`, `fingerprint`, `log_file`.
* field_mappings.md names parsers `apache_combined`, `nginx_combined`, `nginx_json`, `cloudtrail_json`, `gcp_audit_json`, `azure_activity_json`, `winston_json`… — real names are `apache_access`, `nginx_access`, `aws_cloudtrail`, `gcp_cloud_logging`, `azure_activity`, `winston` (some are aliases).
* docs/custom-parsers.md `WHERE 'custom' = ANY(groups)` is not valid DuckDB syntax; use `list_contains(groups, 'custom')`.
* proposals/severity-threshold.md describes a default of `'warning'`; the shipped default is `'all'`.
* examples.md make example shows `make_error` yielding GCC diagnostics; with `'auto'` the same file resolves to `gcc_text` (4 events, no `make: ***` row).

---

## 6. Which formats for which job

### (a) DuckDB extension repos
| Input | Format | Notes |
|---|---|---|
| `make test` / `build/release/test/unittest "test/sql/*.test"` output (Catch-based sqllogictest runner) | `duckdb_test` | Detects `unittest is a Catch`, `test cases:`, lines starting `[N/M] (P%): test/…`, `Wrong result in query!`. Emits one `FAIL` row per failure with `ref_file` = the `.test` file, `ref_line` = the failing query's line (parsed from `Wrong result in query! (path:LINE)!`), `message` = failure line + `Mismatch on row…`, `function_name` = first 50 chars of the failing `SELECT`, `log_content` = query + `--- Expected ---`/`--- Actual ---` blocks, `suggestion` = mismatch line, `category='test_failure'`; plus an `INFO` `test_summary` row from `test cases: X \| Y passed \| Z failed`. Handles: Wrong result / Wrong row count / Wrong column count / Wrong result hash / Query unexpectedly failed / Query unexpectedly succeeded. If nothing found, one INFO row "DuckDB test output parsed (no specific test results found)". **It does not parse `.test` files themselves** — only runner output. Maturity ★ (one sample-based test file, `test/sql/duckdb_test_parser.test`). |
| `make release` / CMake + Ninja + clang/gcc build logs | `'auto'` → `gcc_text` when `file:line:col: error:` present; `cmake_build` for `CMake Error`/`-- Configuring incomplete`; chain `'gcc_text,cmake_build,make_error'` for robustness; `make_error` for `make: *** [target] Error N` rows | `gcc_text` requires compiled-language extensions (`.c/.cpp/.cc/.cxx/.h/.hpp/.f90/…`; rejects `.py`), sets `function_name` from `In function 'x':`, groups multi-line diagnostics into `log_line_start..end`. Ninja lines (`[12/300] Building CXX object …`) are ignored; compiler diagnostics inside are picked up. |
| `clang-tidy` | `clang_tidy_text` | `error_code` = check name; `function_name` empty by design. |
| `valgrind` / crash | `valgrind`, `gdb_lldb` | |
| GitHub Actions job log (raw) | workflow: `read_duck_hunt_workflow_log(f, 'github_actions')`; flat: `read_duck_hunt_log(f, 'github_actions')` (alias of `github_actions_text`) | Workflow parser gives step hierarchy + delegation (`make`→`make_error`, `pytest`→`pytest_text`, level 4). Downloaded run ZIP → `github_actions_zip` with zipfs. `gh run view --log` output → `github_cli`. |
| `.gz` CI logs | any, transparently | |

### (b) Python pytest
* `pytest --json-report --json-report-file=-` → `pytest_json` (best fidelity). Field mapping from source: nodeid `tests/test_auth.py::TestX::test_login` → `ref_file = 'tests/test_auth.py'` (text before the first `::`), `test_name = 'TestX::test_login'` (text after it — **not** the full nodeid, matching examples.md), `function_name = 'test_login'` (class prefix and `[param]` stripped), `ref_line` NULL (never set), `message` = `longrepr` (top-level or `call.longrepr`), `execution_time` = `duration` else `call.duration` (seconds), summary row from the `summary` object (`status='ERROR'` if `failed>0` else `INFO`). `outcome` passed/failed/skipped/error → PASS/FAIL/SKIP/ERROR; **xfailed/xpassed → ERROR** (default branch). Detection requires a `tests` array whose first element has string `nodeid` and `outcome`.
* plain terminal output → `pytest_text` (needs `file.py::test PASSED|FAILED|SKIPPED` lines, i.e. `-v`; short-summary `FAILED …` lines also parsed; FAILURES section supplies `ref_file`,`ref_line`,`message`).
* `pytest --cov` → `pytest_cov_text`; `coverage report` → `coverage_text`; also `mypy_text`, `flake8_text`, `ruff_text`/`ruff_json`, `pylint_text`, `black_text`, `isort_text`, `bandit_json` — or just `format := 'python'`.

### (c) k6 / benchmark output
* **No k6 parser and no generic benchmark parser exist** (grep of src/docs finds none; `PERFORMANCE_METRIC`/`PERFORMANCE_ISSUE` event types exist but only strace/valgrind-style parsers emit them). Options: `regexp:` with named groups (e.g. `'regexp:(?P<name>http_req_duration)\.+:\s+avg=(?P<message>[\d.]+\w+)'`), a JSON-config custom parser via `duck_hunt_load_parser_config`, or k6 `--out json` → parse with DuckDB's native `read_json`/`read_ndjson` instead (duck_hunt's `jsonl` parser only maps `level`/`msg`/`time`-style log fields and will treat metric points as generic log rows). Go `testing.B` benchmark lines are **not** handled by `gotest_text` (only PASS/FAIL/SKIP).

### (d) Generic application / JSON logs
* One-JSON-object-per-line → `jsonl` (`ndjson`), priority 50 so any specific JSON logger parser (`pino`, `bunyan`, `winston`, `logrus`, `serilog`) outranks it under `auto`. `key=value` → `logfmt`. Python stdlib `%(asctime)s - %(name)s - %(levelname)s - %(message)s` → `python_logging`. Java → `log4j` (`logback` alias). .NET → `serilog`/`nlog`. Ruby → `ruby_logger`/`rails_log`. syslog → `syslog`. Web → `apache_access`/`nginx_access`/`apache_error`. Container/cluster → `kubernetes`, `docker_build` (flat) / workflow `docker_build`. Cloud audit → `aws_cloudtrail`, `gcp_cloud_logging`, `azure_activity`. Use group `'logging'` to try them all. Fields: `severity` from level, `started_at` timestamp, `category` logger name, `origin` host, `external_id` request/trace id, `structured_data` = remaining JSON fields; apply `severity_threshold := 'warning'` to drop info/debug.
* For anything else: `regexp:` (single-line only) or a JSON custom parser with `detection` so it participates in `auto`.

-- @ext: duck_hunt
-- @rev: 68ca1c4 (community, DuckDB 1.5.5 osx_arm64)
-- @verified: 2026-09-17 on GitHub Actions run ZIPs from asubbarao/quackapi and inframe-risk/inframe
-- @functions: read_duck_hunt_log, parse_duck_hunt_log, read_duck_hunt_workflow_log, parse_duck_hunt_workflow_log, duck_hunt_diagnose_read, duck_hunt_diagnose_parse, duck_hunt_formats, duck_hunt_detect_format, duck_hunt_load_parser_config, status_badge
-- @needs: zipfs (zip:// and github_actions_zip); gh CLI for run logs
-- @tags: ci, github actions, test results, pytest, build errors, make, log parsing, fingerprint, why is ci red
-- @summary: Test/build/CI output as one 39-column event table (status, severity, ref_file, ref_line,
--   test_name, fingerprint, …). Workflow parser gives the step tree; tool parsers give diagnostics;
--   read the job file twice. 110 formats, regexp: for the rest.
LOAD zipfs; LOAD duck_hunt;

-- Get a run: gh api repos/<owner>/<repo>/actions/runs/<run_id>/logs > run.zip   ({N}_{job}.txt per job)
-- Ask the contest first — auto looks at 8 KB only:
FROM duck_hunt_diagnose_read('failed.log') WHERE can_parse;        -- format, priority, events_produced, is_selected

-- read_duck_hunt_workflow_log(source, format) ; format auto|github_actions|gitlab_ci|jenkins|docker_build|spack|github_actions_zip
--   named: severity_threshold := 'all'   -> 39-col schema minus log_file, plus workflow_type, hierarchy_level (1 workflow,
--   2 job, 3 step, 4 delegated tool event), parent_id, job_order, job_name (zip only)
SELECT job_name, unit AS step, unit_status, severity, left(message, 120) AS message
FROM read_duck_hunt_workflow_log('run.zip', 'github_actions_zip')
WHERE severity IN ('error', 'critical') OR unit_status = 'failure';

-- read_duck_hunt_log(source, format := 'auto', severity_threshold := 'all', content := 'full', context := 0)
--   source: path | glob | zip://… | /dev/stdin | .gz ; format: name | alias | group ('python','test','build','lint','ci','logging')
--   | chain 'gcc_text,make_error' | 'regexp:<pattern>'   -> 39 cols (+ context LIST when context > 0)
-- make_error is what surfaces the exit reason of a DuckDB extension test job:
SELECT ref_file, message FROM read_duck_hunt_log('zip://run.zip/4_Build extension binaries _ linux_amd64.txt', 'make_error');
--   → make: *** [extension-ci-tools/makefiles/duckdb_extension.Makefile:218: test_release] Error 134   (134 = SIGABRT)

-- pytest-xdist -v prints "[gw0] [ 12%] PASSED nodeid"; pytest_text wants "nodeid PASSED" and returns 0 rows.
-- The regexp: format with named groups (severity, file, test_name, message, line, code, tool) recovers every test:
CREATE TEMP TABLE tests AS
SELECT log_file, severity AS outcome, ref_file AS file, test_name
FROM read_duck_hunt_log('zip://run.zip/*Backend Tests Shard*.txt',
  'regexp:\[gw\d+\] \[\s*\d+%\] (?P<severity>PASSED|FAILED|SKIPPED|ERROR|XFAIL|XPASS) (?P<file>[^:\s]+)::(?P<test_name>\S+)');
SELECT log_file, outcome, array_agg(file || '::' || test_name) AS tests, len(tests) AS n FROM tests WHERE outcome <> 'PASSED' GROUP BY ALL;
--   18,145 tests over three shards, equal to the "=== N passed ===" lines. Permanent fix: pytest --json-report → pytest_json.

-- Application logs from a string (CloudWatch body, a Slack paste): parse_duck_hunt_log(text, format)
SELECT e.severity, e.category AS logger, e.message
FROM (SELECT string_agg(body, chr(10) ORDER BY ts) AS log FROM backend) b, LATERAL parse_duck_hunt_log(b.log, 'python_logging') e;

-- A shape no built-in covers (inframe backend: JSON lines interleaved with two-line uvicorn access records)
-- registers as a custom parser and then takes part in 'auto':
SELECT duck_hunt_load_parser_config('{
  "name": "inframe_backend",
  "detection": {"contains_all": ["\"logger\":", "\"level\":"]},
  "priority": 90,
  "patterns": [
    {"regex": "\"level\": \"(?P<severity>[A-Z]+)\".*\"logger\": \"(?P<category>[^\"]+)\".*\"message\": \"(?P<message>[^\"]*)\"", "event_type": "UNKNOWN"},
    {"regex": "^\\s+(?P<severity>INFO|WARNING|ERROR)\\s+(?P<file>[0-9.]+:\\d+) - \"(?P<message>[A-Z]+ [^\"]+)", "event_type": "UNKNOWN", "category": "uvicorn"}
  ]}');

-- Cluster errors across files (fingerprint/pattern_id are NULL in streaming mode: use a glob or context := 1)
SELECT fingerprint, count(DISTINCT log_file) AS runs, count(*) AS n, any_value(message) AS example
FROM read_duck_hunt_log('logs/*.txt', 'auto') WHERE severity = 'error' GROUP BY 1 ORDER BY runs DESC;

-- Gotchas: missing file = 0 rows, no error; event_type lowercase, status UPPER, severity lower; "group" needs quoting;
-- severity_threshold typos silently become 'warning'; named params do not bind inside LATERAL; a format ending in
-- .json is fetched as a parser config; execution_time is whatever the tool printed (pytest: seconds).

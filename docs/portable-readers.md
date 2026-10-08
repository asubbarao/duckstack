# Portable evidence readers

The reference SQL files `skills/ci-timing/references/github_run.sql`,
`skills/ci-timing/references/github_jobs.sql` and `skills/duck-hunt/references/log_events.sql`
have no dependency on a local server or an agent's personal instructions.
Run with DuckDB 1.5.5 on macOS arm64 or Linux; each SQL file installs/loads its own extensions.
Community extension installation needs network access on its first run and a supported
binary platform (CI is configured to exercise Linux; development checks macOS arm64).

```bash
CI_REPO=owner/repo CI_RUN_ID=123 uvx --from duckdb-cli==1.5.5 duckdb :memory: -bail -json -f skills/ci-timing/references/github_run.sql
CI_REPO=owner/repo CI_RUN_ID=123 uvx --from duckdb-cli==1.5.5 duckdb :memory: -bail -json -f skills/ci-timing/references/github_jobs.sql
CI_LOG_PATH='reports/*.xml' CI_LOG_FORMAT=junit_xml uvx --from duckdb-cli==1.5.5 duckdb :memory: -bail -json -f skills/duck-hunt/references/log_events.sql
```

The relative SQL paths above assume the repository root. `uv` supplies the pinned CLI;
installing Python's `duckdb` package does not install that executable. A Python DuckDB
connection can execute the same SQL files with `connection.execute(path.read_text())`.

GitHub acquisition additionally needs `gh` on the DuckDB process's PATH and permission
to read that repository (`gh auth status` checks credentials). ShellFS loads the pipe
filesystem; it does not install or authenticate the command it executes. Run metadata
retains all API columns. Job pages retain the full `jobs` list, nested steps and the page's
`total_count`; that count repeats across pages and must not be summed. GitHub's default
jobs endpoint selects the latest attempt. Use `SELECT unnest(jobs) AS job` downstream
for one row per job. A rerun can change the live result. Use a
run-attempt endpoint when historical attempt isolation is required.

No row, duration or status policy is built into these sources. Apply filters, joins,
ordering and preview limits downstream. A SELECT limit does not limit GitHub acquisition:
`github_jobs.sql` fetches all pages for one run, not every run in a repository.
An empty run retains its page with `jobs=[]`; a command/API/JSON failure is an error,
not a green result. Empty JSON lists have no inferred struct fields: expand populated
job records downstream, not `job.*` in the source reader.
Save responses with COPY when reproducible analysis needs snapshots; these examples
are live reads, not a cache or a durable acquisition-receipt pipeline.

For logs, prefer structured reports such as JUnit XML to heuristic text parsing.
`log_events.sql` also installs/loads `webbed`, which Duck Hunt's XML parsers require
in the executing connection. The smoke includes a pytest-style JUnit report with
passed and failed cases and source-provided durations. Choose
the actual tool format instead of treating every Actions log as `github_actions`.
Raw content survives alongside every event; no parser matches produce a NULL event_id
row, not proof that the tool succeeded. Missing file/glob matches produce zero source
rows; this is missing evidence, never a clean test result. Invalid UTF-8 is an error.
The correlated parser itself may return no events for an unknown format. This example
checks exact names against `duck_hunt_formats()` so misspelled formats are errors.
Custom parser configuration strings and aliases require adapting this check explicitly.
`read_text` batches
whole documents in memory, so use bounded report files rather than enormous logs.
Execution-time units depend on the parser; unknown times may be zero. Event IDs and
fingerprints are not universal persistent identifiers.

ShellFS recognizes a command only when the path ends in `|`; do not leave whitespace
or a newline after that final pipe inside the SQL string.

For a git revision inventory, use `git_tree(repo, ref) WHERE kind = 'file'` from
`skills/duck-tails/SKILL.md`; it reads committed content without a checkout.

The tests execute these SQL files using real extensions and local deterministic
fixtures. A fake `gh` is only the acquisition boundary; it does not mock DuckDB,
ShellFS or the parsers. Run with:

```bash
uv run --no-project --with pytest --with duckdb-cli==1.5.5 python -m pytest tests/test_readers.py -q
```

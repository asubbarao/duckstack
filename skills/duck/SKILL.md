---
name: duck
description: >
  The DuckDB execution boundary and SQL process rules for this machine — read before any
  DuckDB work. Dev and agent-owned DuckDBs are disposable runtimes rebuilt from SQL; every caller
  uses an explicitly selected MCP, QuackAPI or Quack endpoint.
  Use whenever a task touches DuckDB, the duckstack, quack, the dev MCP,
  crawler/webbed, Chrome-as-relations, or when an agent is about to write SQL for this user.
  Every other duckdb-skills skill assumes this one.
argument-hint: "[topic: boundary | client | rules | repos | facts]"
allowed-tools: mcp__dev__query, mcp__dev__execute
---

The **duckstack** is source-defined, not file-defined. Dev is the convenient shared default; an
agent may also own a fresh `:memory:` instance. In either case, callers use an explicitly selected
network door. SQL definitions and skills are authoritative; database files and WALs are rebuildable
outputs, not irreplaceable state.

## Query first

Read [references/query-first.md](references/query-first.md) before building a data-generation or exploration workflow. It contains a runnable UNPIVOT example, measured checks, and guidance for choosing native readers, LATERAL, or self-dispatch. Start with a SELECT and rerun it; do not create tables/views, export files, or design a framework before its grain is correct.

## 1. The stack

The selected MCP is the primary agent workspace: `query` for a SELECT, `execute` for
everything else (native readers, ShellFS, DDL, COPY). Row-driven work is SQL that
posts one statement per row to `/sql` (/duckstack:self-dispatch). Start with the
MCP forms in agent-door, not the historical standalone/client examples below. No
new macro without explicit approval.

| Door | What | Token | Who |
|---|---|---|---|
| `dev` MCP (`query`, `execute` tools) | duckdb_mcp inside dev on `http://127.0.0.1:9496/mcp` | none, loopback | any agent with the MCP — `/duckstack:agent-door` |
| `http://127.0.0.1:9495/sql` | quackapi route inside dev; runs any SQL | none, loopback | any agent with a shell; dev's own self-dispatch |
| `quack:localhost:9494` | dev, read-write | `~/.duck/token` | `quack_query` from a `:memory:` client |
| OTLP `http://127.0.0.1:4318/v1/*` | `otlp_serve` inside dev; rows land in `otlp_logs`, `otlp_traces`, `otlp_metrics_*` | none, loopback | telemetry senders |

`~/.duck/dev.duckdb` is held open by `com.inframe.quack` (launchd `KeepAlive`); `~/.duck/setup.sql`
is the dev definition (a symlink to the copy in git, `~/duckdb-skills/server/setup.sql`). A watcher
restarts it when server SQL changes. In-flight queries may die; agents announce the restart and retry
only reads or writes proven not to have happened.
DuckDB **1.5.5** osx_arm64. Server extensions: `~/.duck/extensions`; local CLI: `~/.duckdb/extensions`.

## 2. The boundary (hard rules)

Use the selected MCP query/sql tools first, including readers and ShellFS host work.
If unavailable in the harness, use the same service's QuackAPI or quack_query.
Give subagents this endpoint. Missing tool exposure is not service failure.

1. **Nobody opens the file.** `~/.duck/dev.duckdb` is locked; even `-readonly` is refused.
   A lock error means the caller is wrong. Go through `quack_query` instead.
2. **A `duckdb :memory:` is a stateless client.** It may `LOAD quack` and talk to an
   *explicitly selected* `quack:localhost:<port>`, call an explicitly selected localhost
   service, or use the `dev` MCP when `dev` is the target. Never assume there is only one
   Quack; never silently substitute one localhost service for another.
3. **Definitions live in source.** Required schemas, views, macros, tools and schedules belong in
   replayable SQL. Runtime tables may live on the selected service, but deleting dev plus its WAL
   must not erase the system definition. Agent-owned instances use `own_server.sql`; durable evidence
   publication is a separate stage.
4. **`~/.duckdbrc` is the resource floor** (4 threads, 4 GiB, temp dir, per-process
   QueryLog/Metrics/HTTP capture). `-c`, `-f` and `-cmd` keep it; `-init` *replaces* it
   (verified: 15 threads / 38 GiB, no telemetry). Never `-init`.
5. **Install and load needed community extensions on the selected service.** Inspect
   actual errors rather than assuming configuration locking prohibits all extension work.
   Send LOAD separately before batches using extension PRAGMAs or parser syntax.
   Persist required startup loads in setup.sql when maintaining the service.
6. **Spell URIs `quack:host:port`.** That is the repo standard and what every secret `SCOPE`
   is written against (a literal prefix match). Verified 2026-09-17 on quack c154811: the
   `quack://host:port` spelling *also* works for `quack_query`, so the inframe CONTEXT.md line
   "`quack://` is not dispatched" is stale — the rule is consistency with the secrets, not a
   parser limit.
7. **The token is an environment variable on the shell line, never a literal in SQL, never in
   a file, never printed.** `QUACK_TOKEN="$(cat ~/.duck/token)" duckdb :memory: …` and
   `getenv('QUACK_TOKEN')` in the statement.
8. **Column-bound table functions self-dispatch.** For each URL row, render a literal
   `crawl(...)` or `crawl_url(...)` statement and post it to the selected service. A binding
   complaint means this step was skipped. `read_lines_lateral` remains an explicit supported
   correlation: `FROM rel CROSS JOIN LATERAL read_lines_lateral(rel.col)`.
9. **Do not claim a timeout exists because a config reports one.** duckdb_mcp a6b8648 shows
   `request_timeout_seconds 30` in `mcp_server_config()` and enforces nothing; the launchd
   process ceilings are the boundary.

## 3. The client — three forms, all stateless (verified 2026-09-17, quack c154811)

**One statement, no attach** — a probe, a count, one landed table:

```bash
QUACK_TOKEN="$(cat ~/.duck/token)" duckdb :memory: -c "
LOAD quack;
-- quack_query(uri, sql, disable_ssl := false, token := ...) : one statement on the server, no session
FROM quack_query('quack:localhost:9494', \$\$FROM whoami()\$\$, token := getenv('QUACK_TOKEN'));"
```

**A session in one process** — don't. Use `quack_query`; see `/duckstack:quack`. ATTACH is
broken on DuckDB 1.5.5 (duckdb-quack#132) and was the weaker form before that.

**A `.sql` artifact** — the deliverable when there is more than one statement. Head = `LOAD
quack;` and the provenance comment; body = one table per statement, raw first, each inside a
`quack_query` body; tail = verification queries as comments. Run it by path, `-f` keeps the rc
floor:

```bash
QUACK_TOKEN="$(cat ~/.duck/token)" duckdb :memory: -f crawl_duckdb_docs.sql
```

`references/head.sql` is the head to copy. The artifact is also the surface a human edits
(the console idea below): plain SQL, runnable blocks, `--#` lines are instructions to the agent.

What each path can and cannot do. The `dev.` rows need an ATTACH and so are unavailable on
1.5.5; they are kept because they say what the body should contain instead.

| From the client | Result |
|---|---|
| `quack_query(uri, $$…$$)` | on the server; joins, aggregates, `CREATE`, table functions — the form to use |
| `SELECT … FROM dev.t` (one table) | needs ATTACH — put the table in the body instead |
| `SELECT … FROM dev.a JOIN dev.b` client-side | **fails** "Multiple streaming scans" → join inside the body |
| client-side `duckdb_tables()` for dev | **0 rows** — the remote catalog is not mirrored; ask inside the body |
| `quack_query(…, $$SET …$$)` | "configuration has been locked" |
| after a launchd restart | nothing to re-establish — `quack_query` holds no session |

Macros defined on dev do not resolve client-side; call them inside the body.

## 4. The reference repos — what the pattern actually is

The user's own repos, read at `~/Documents/Codex/2026-09-16/how-to-integrate-connect-my-personal-2/work/`
(private, `git@github-asubbarao:asubbarao/<repo>.git`). These are the style guide; upstream
duckdb-skills is not.

**conduit** (`duckdb-ops-toolkit/conduit`) — *the query language is the client.* An external,
side-effecting capability, exposed as a relation, composed inside a query, mutation pushed to
the tail. Grammar is data (`seam_catalog` rows carry only what varies), construction is a view,
execution is scalars firing per row inline. Six macros total, each a wire mechanic or a
fail-closed gate (`request`, `with_auth`, `cookie_parse`, `retryable`, `shell_sleep`,
`xml_payload_checked`) — never a rename of an extension function, never a stage. The composed
chain is CTEs visible at the call site: bind (JOIN to the catalog) → fire (`request()` over
columns) → barrier (`array_agg` → `UNNEST WITH ORDINALITY`) → classify (ONE `CASE`) →
terminal / to_retry (two `WHERE`s). Retry is an unrolled ladder gated by CTE cardinality
(never `CASE` around a network call — it does not short-circuit). Pagination is a relation
(`range()`, probe-then-fan, unrolled cursor rungs), never `WITH RECURSIVE`. `sql/conduit.sql`
+ `sql/capstone.sql` are the whole thing.

**Self-dispatch** — *the database writes the statement it cannot bind, then runs it.* Table
functions bind literals; a scalar takes columns; so build the statement per row and hand it to
a scalar that runs SQL. Three forms verified on this machine 2026-09-17, all in
`/duckstack:self-dispatch`: (1) **quackapi in-process** — `CREATE ROUTE dispatch POST '/q' AS SELECT rows.* FROM query($q)
rows; quackapi_serve(port)` in the same `:memory:` process, `array_agg(http_post(url,
MAP{'Content-Type':'application/json'}, json_object('q', q)))`, `UNNEST WITH ORDINALITY`, a JSON array of typed rows back, `quackapi_stop()`; (2) **two constant shellfs pipes** —
an inner duckdb `COPY`s generated statements to stdout, a child duckdb (or `bash`) runs them;
(3) **quack loopback** — a body that itself calls `quack_query('quack:localhost:9494', '…',
token := getenv('QUACK_TOKEN'))`, the server calling itself. Posting `q=` to quack's own port is the
error every agent makes (`status -1`); the executor port is a parameter, not a fact.

**duckdb-chrome-bridge** — *your logged-in Chrome is a set of DuckDB relations.* macOS
osascript over the Chrome already running (no CDP/Playwright/fresh profile), via `shellfs`
`read_csv('osascript … |')`. `chrome_window_tabs` is the locate surface; `chrome_at(url_prefix,
js)` locates and evaluates in one osascript (coordinates typed by hand return the wrong tab's
DOM with no error); `chrome_settle` makes readiness a value; `chrome_exhaust` drives infinite
scroll on entity count, not scrollHeight; `chrome_routes` / `chrome_entities` discover the
entity segment instead of guessing an extractor. **Never `chrome_open` to read** — it stomps
the user's tab. Chrome hands over RAW markup only; everything after is webbed/crawler/quickjs.
Needs Chrome ▸ View ▸ Developer ▸ "Allow JavaScript from Apple Events" and the Automation grant
for the process that runs the query.

**claudes-console** — the human is faster at SQL than the agent. The agent stages SQL into a
real `.sql` the human edits in their IDE; **`--#` lines are human → agent instructions**; the
agent executes the same file by path against quack and reads real results back; every round
is a git commit; the server's query log is the flipbook ("go back to that query" is a query,
not a re-paste). Neither side pastes SQL at the other through chat.

## 5. SQL process rules (procedures, not style)

Project scalars directly: SELECT 'widget' AS term, * FROM items. No any_value or
CROSS JOIN in agent-authored queries. Expand lists with SELECT unnest(arr); use
SELECT unnest(range(n)) when intentionally repeating rows. Native correlated
JOIN LATERAL calls remain available; do not disguise a Cartesian product as a join.

Verbatim source: `~/.duck/catalog/2026-09-15.md`. Breaking one is a procedural failure.

- **No extraction until you are an expert in the data.** No `html_extract_*` on raw strings,
  `json_extract` ladders, `col0/col1/col2`. Reader first, whole document kept, `DESCRIBE`,
  then select by name.
- **`regexp_*` is categorically banned** without a petition stating why a reader or a typed
  cast cannot do it. `LIKE` on markup is the same offence.
- **No enumeration = no lossy aggregation.** No `p[-4]`, `split_part(path,'=',2)`, no
  `COUNT(*)`/`min`/`max`/`avg` in base layers — `array_agg(x) AS xs, len(xs) AS n`.
- **`coalesce((SELECT …), 0)` is an antipattern.** A scalar subselect with no reason is a join
  written badly, and `coalesce` around one is a second smell: `count(*)` never returns NULL, so
  `coalesce((SELECT count(*) FROM approvals a WHERE a.proposal_id = p.id), 0)` protects against
  something the inner expression cannot produce. Join the child table (`LEFT JOIN`, aggregated in
  its own CTE) and put the `coalesce` on the outer column, where a missing match really does yield
  NULL. Ask what the wrapper defends against and whether that can happen.
- **Nested parens `(([((` are often, but not always, an antipattern.** They usually mean a query
  built inside-out where named CTEs reading top to bottom would say it directly. Do not flag
  parentheses mechanically — flag the subselect that has no reason to be one.
- **No string surgery on structure.** raw → cast with the extension's type (`::HTML`, `::XML`,
  `::JSON`) → the extension's functions. URLs are strings: `netquack`/`urlpattern`, or literal
  `string_split`; markup is a tree: webbed XPath / crawler CSS.
- **Keep every row and every column in base layers.** "The scrape of page X" is a query whose
  `SELECT *` is a tabular grid of X; upstream CTE columns stay even if unprojected.
- **One layer (one column, even) at a time. Never one-shot.** Iterate on a plain query; a view
  only once it is right. CTEs, not subqueries inside table-function arguments.
- **Start with a bounded slice / `WHERE name IN (…)` and widen.** Incremental, 3–5 at a time;
  `cron()` hydrates the rest.
- **No macros yet** — until the shape of the data is "just known". Conduit's six are the
  ceiling, and each is a wire mechanic or a gate.
- **Every function call carries a comment listing all its parameters and defaults.**
- **Single `.sql` deliverable.** No `.sh`, no Python in the data path; launchd plists are the
  one shell-side artifact. One table per statement, raw first.
- **Progress is the query getting shorter.** 269 → 212 → 150 → 68 → 24 lines.
- **SQL-and-join beats stdout.** Land results as tables on dev; a pasted blob is the worse
  interface.

## 6. Verified 1.5.5 facts (from `~/inframe/internal/duckdb/CONTEXT.md`, maturity `poc`)

- Secret-manager settings must precede the first `LOAD httpfs`/`aws`; `allow_community_extensions`
  and `custom_user_agent` cannot change while running.
- `read_html` is registered by **both** `crawler` and `webbed`; named parameters only.
  `record_element := 'tr'` silently ignores `attr_mode`/`attr_prefix`; `htmlpath(…'@href[*]')`
  returns NULL; `jq()` is first-match only.
- `crawl()`/`crawl_url()`/`quack_query()` are table functions: arguments bind
  literals, `getenv`, `getvariable` or pure concatenation — never a column. Apply either crawl
  function per URL row by rendering a literal statement and self-dispatching it. Treat a binder
  complaint as a missing dispatch stage, not an extension limitation.
- `enable_logging(..., storage_path := '…csv')` writes ONE denormalized file; `QueryLog` is a
  start record, not a completion record.
- `COPY … PARTITION_BY` writes one file per partition (`FILENAME_PATTERN 'part'` → `part0.parquet`)
  — that is what makes a daily snapshot idempotent; `FORMAT json` cannot `PARTITION_BY`.
  DuckLake needs `DATA_INLINING_ROW_LIMIT 0` or small inserts never reach S3.
- duckdb_mcp: `execute` has no file-access denylist (`query` does); each tool call is a fresh
  connection; `.mode trash` is required on stdio; markdown cells with newlines split rows in
  a6b8648.
- launchd: a changed plist needs `bootout` + `bootstrap`; `kickstart -k` reruns the old one.
- Codex `workspace-write` mounts `.git` read-only: its runs cannot branch or commit.

## 7. Which skill

| Want | Skill |
|---|---|
| run SQL — one statement, or a `.sql` artifact | `/duckstack:query` |
| pages as tables: crawler × webbed, or logged-in Chrome for SPAs/auth | `/duckstack:crawl` |
| which door to use — MCP, `/sql`, quack | `/duckstack:agent-door` |
| a table function needs a column; per-row fan-out; "lateral join column parameters" | `/duckstack:self-dispatch` |
| git history / GitHub as tables (`duck_tails`, `gh`) | `/duckstack:git-github` |
| a data file locally or over HTTP/S3 | `/duckstack:read-file` |
| DuckDB docs | `/duckstack:duckdb-docs` |

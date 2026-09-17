---
name: duck
description: >
  The DuckDB execution boundary and SQL process rules for this machine — read before any
  DuckDB work. One persistent dev DuckDB is held locked by a quack server; every agent is a
  stateless `:memory:` client that LOADs quack and talks to it — one statement, or one `.sql`
  artifact. Use whenever a task touches DuckDB, the duckstack, quack, the dev MCP,
  crawler/webbed, Chrome-as-relations, or when an agent is about to write SQL for this user.
  Every other duckdb-skills skill assumes this one.
argument-hint: "[topic: boundary | client | rules | repos | facts]"
allowed-tools: Bash
---

You are working on a machine whose data substrate is the **duckstack**: one persistent DuckDB
per machine, always on, always locked, reached only through the network. The stock
duckdb-skills model ("open `file.duckdb`, keep a session file, `INSTALL` what you need") is
wrong here. This skill is the record label the other skills ship under.

## 1. The stack

| Door | What | Token | Who |
|---|---|---|---|
| `quack:localhost:9494` | dev, read-write | `~/.duck/token` | humans and the main agent |
| `quack:localhost:9495` | dev, read-only, gated | `~/.duck/token.ro` | agents; `dev_gate` refuses anything the parser does not see as exactly one SELECT |
| `http://localhost:9496/mcp` | the MCP sidecar (`dev` in Claude/Codex MCP config) | none, loopback | agents that only have MCP — `/duckdb-skills:agent-door` |
| `quack:localhost:9497` + OTLP `:4318` | telemetry DuckDB | `~/.duck/telemetry/` | observability |

`~/.duck/dev.duckdb` is held open by `com.inframe.quack` (launchd `KeepAlive`); `~/.duck/setup.sql`
is THE server, identical on every machine (source: `~/inframe/internal/duckdb/setup.sql`).
DuckDB **1.5.5** osx_arm64. Server extensions: `~/.duck/extensions`; local CLI: `~/.duckdb/extensions`.

## 2. The boundary (hard rules)

1. **Nobody opens the file.** `~/.duck/dev.duckdb` is locked; even `-readonly` is refused.
   A lock error means the caller is wrong. Attach the quack instead.
2. **A `duckdb :memory:` is a stateless client.** It may `LOAD quack` and talk to an
   *explicitly selected* `quack:localhost:<port>`, call an explicitly selected localhost
   service, or use the `dev` MCP when `dev` is the target. Never assume there is only one
   Quack; never silently substitute one localhost service for another.
3. **Persistent state lives on the server.** Tables, views, secrets, crawl state, cron — on
   dev. **There is no client-side session to restore: no `state.sql`, no `.read`, no `-init`.**
   Anything an agent would "remember" between calls is a table on dev.
4. **`~/.duckdbrc` is the resource floor** (4 threads, 4 GiB, temp dir, per-process
   QueryLog/Metrics/HTTP capture). `-c`, `-f` and `-cmd` keep it; `-init` *replaces* it
   (verified: 15 threads / 38 GiB, no telemetry). Never `-init`.
5. **No `SET`, `INSTALL`, `LOAD` against dev** — `lock_configuration = true` is the last
   statement of `setup.sql` ("the configuration has been locked"); `autoinstall_known_extensions
   = false`. Endpoints, regions, URL styles are **secrets**, never settings. Anything a server
   needs goes in `setup.sql`, nowhere else.
6. **Spell URIs `quack:host:port`.** `quack://…` is silently not dispatched to the extension.
   A secret's `SCOPE` is a literal prefix match on that spelling.
7. **The token is an environment variable on the shell line, never a literal in SQL, never in
   a file, never printed.** `QUACK_TOKEN="$(cat ~/.duck/token)" duckdb :memory: …` and
   `getenv('QUACK_TOKEN')` in the statement.
8. **Lateral functions are correlated or they do not run.** `crawl_url`, `read_lines_lateral`
   only as `FROM rel CROSS JOIN LATERAL f(rel.col)`. The incident behind this rule was an
   uncorrelated lateral run locally.
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

**A session in one process** — attach, then `dev.query($$…$$)` is the sticky server-side
session (TEMP tables, `SET VARIABLE`, joins, table functions all run on dev):

```sql
LOAD quack;
-- ATTACH uri AS name (TYPE quack, TOKEN ...)  -- READ_ONLY only blocks the client catalog path; the gate is server-side
ATTACH 'quack:localhost:9494' AS dev (TYPE quack, TOKEN getenv('QUACK_TOKEN'));
FROM dev.query($$FROM whoami()$$);
```

**A `.sql` artifact** — the deliverable when there is more than one statement. Head = those two
lines; body = one table per statement, raw first; tail = verification queries as comments.
Run it by path, `-f` keeps the rc floor:

```bash
QUACK_TOKEN="$(cat ~/.duck/token)" duckdb :memory: -f crawl_duckdb_docs.sql
```

`references/head.sql` is the head to copy. The artifact is also the surface a human edits
(the console idea below): plain SQL, runnable blocks, `--#` lines are instructions to the agent.

What each path can and cannot do:

| From the client | Result |
|---|---|
| `FROM dev.query($$…$$)` | on the server, sticky session; joins, aggregates, `CREATE`, table functions |
| `SELECT … FROM dev.t` (one table) | works — a streaming scan through the attach |
| `SELECT … FROM dev.a JOIN dev.b` client-side | **fails** "Multiple streaming scans" → push into `dev.query` |
| client-side `duckdb_tables()` for dev | **0 rows** — the remote catalog is not mirrored; ask via `dev.query` |
| `quack_query('…9495', $$CREATE …$$)` | "Authorization failed" — the parser gate |
| `dev.query($$SET …$$)` | "configuration has been locked" |
| after a launchd restart | `DETACH dev; ATTACH …` — or just run the artifact again |

Macros defined on dev do not resolve as `dev.main.macro()`; call them inside `dev.query()`.

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

**Self-dispatch** (`conduit/docs/self-dispatch*.md`) — the server runs SQL it built at runtime
by querying **itself**. Canonical form: the server `ATTACH`es itself as `self` in its init and
runtime-built SQL runs as `FROM self.query('…')` with no per-call token. **Not present on this
dev yet** (`duckdb_databases()` on 9494 shows only `dev`) — a `setup.sql` change if wanted.
The scalar molecule (`array_agg(http_post_form(executor, MAP{}, MAP{'q': q})) … CROSS JOIN
UNNEST … WITH ORDINALITY`) is the *exception* for genuine per-row scalar fan-out — a table
function that rejects a column argument — and needs a co-resident httpserver, not quack's port.

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

Verbatim source: `~/.duck/catalog/2026-09-15.md`. Breaking one is a procedural failure.

- **No extraction until you are an expert in the data.** No `html_extract_*` on raw strings,
  `json_extract` ladders, `col0/col1/col2`. Reader first, whole document kept, `DESCRIBE`,
  then select by name.
- **`regexp_*` is categorically banned** without a petition stating why a reader or a typed
  cast cannot do it. `LIKE` on markup is the same offence.
- **No enumeration = no lossy aggregation.** No `p[-4]`, `split_part(path,'=',2)`, no
  `COUNT(*)`/`min`/`max`/`avg` in base layers — `array_agg(x) AS xs, len(xs) AS n`.
- **No string surgery on structure.** raw → cast with the extension's type (`::HTML`, `::XML`,
  `::JSON`) → the extension's functions. URLs are strings: `netquack`/`urlpattern`, or literal
  `string_split`; markup is a tree: webbed XPath / crawler CSS.
- **Keep every row and every column in base layers.** "The scrape of page X" is a query whose
  `SELECT *` is a tabular grid of X; upstream CTE columns stay even if unprojected.
- **One layer (one column, even) at a time. Never one-shot.** Iterate on a plain query; a view
  only once it is right. CTEs, not subqueries inside table-function arguments.
- **Start at `LIMIT 1` / `WHERE name IN (…)` and widen.** Lazy, incremental, 3–5 at a time;
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
- `crawl()`/`crawl_url()`/`quack_query()`/`dev.query()` are table functions: arguments bind
  literals, `getenv`, `getvariable` or pure concatenation — never a column. The correlated form
  is `CROSS JOIN LATERAL crawl_url(rel.url, …)`; a previous stage's list rides in via
  `SET VARIABLE urls = (SELECT list(url) FROM …)`.
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
| pick a door, probe it, list what is on it | `/duckdb-skills:attach-db` |
| run SQL — one statement, or a `.sql` artifact | `/duckdb-skills:query` |
| pages as tables: crawler × webbed, or logged-in Chrome for SPAs/auth | `/duckdb-skills:crawl` |
| what the MCP sidecar can reach, raw JSON-RPC | `/duckdb-skills:agent-door` |
| git history / GitHub as tables (`duck_tails`, `gh`) | `/duckdb-skills:git-github` |
| a data file locally or over HTTP/S3 | `/duckdb-skills:read-file` |
| DuckDB docs | `/duckdb-skills:duckdb-docs` |

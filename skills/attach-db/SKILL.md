---
name: attach-db
description: >
  Pick the door and prove it answers: the dev quack (default), the read-only door, another
  quack:host:port, a Superhuman Docs document, or a plain .duckdb file no server holds. Probes
  it, lists what is on it (tables, columns, estimated rows) from the server's own catalog, and
  hands back the two-line ATTACH head every statement or .sql artifact starts with. No state
  file — the attach is a line in every invocation.
argument-hint: "[dev | dev-ro | quack:host:port | superhuman:<doc-id> | <path.duckdb>] [--as alias]"
allowed-tools: Bash
---

You are choosing which database an agent talks to, and proving it. Read `/duckdb-skills:duck`
first: the dev database is a locked, always-on quack server, not a file, and there is no
session file to write — every later statement carries its own `LOAD quack; ATTACH …`.

Target given: `$0` (default `dev`). Optional alias: `--as <name>`.

## Step 1 — Resolve the target

| `$0` | Head (the two lines every statement starts with) | Token on the shell line |
|---|---|---|
| `dev` or empty | `LOAD quack; ATTACH 'quack:localhost:9494' AS dev (TYPE quack, TOKEN getenv('QUACK_TOKEN'));` | `QUACK_TOKEN="$(cat ~/.duck/token)"` |
| `dev-ro` | `… 'quack:localhost:9495' AS dev (TYPE quack, READ_ONLY, TOKEN getenv('QUACK_TOKEN_RO'))` | `QUACK_TOKEN_RO="$(cat ~/.duck/token.ro)"` |
| `quack:host:port` | same shape with that URI; ask which token file, never accept a pasted token | that file |
| `superhuman:<doc-id or URL>` | Step 3b | the Superhuman API token file |
| `<path>.duckdb` | `ATTACH '<path>' AS <stem> (READ_ONLY);` — **only** if no server holds it | none |

`~/.duck/dev.duckdb`, `~/.duck/scratch.duckdb`, `~/.duck/telemetry/*.duckdb` are server-held:
refuse and use the quack target. "Could not set lock on file" on any other `.duckdb` means a
server holds that one too — say so.

## Step 2 — Probe (one statement, no session)

```bash
QUACK_TOKEN="$(cat ~/.duck/token)" duckdb :memory: -c "
LOAD quack;
-- quack_query(uri, sql, disable_ssl := false, token := ...) : one statement on the server
FROM quack_query('quack:localhost:9494', \$\$SELECT name, uptime, meta->>'port' AS port, meta->>'duckdb_version' AS v FROM whoami()\$\$, token := getenv('QUACK_TOKEN'));
" 2>&1 | grep -v 'Loading resources'
```

Expect `name = dev`, `port = 9494`, `v = v1.5.5`. Anything else: the server is down or the
token file is wrong — report; do not retry with a different port, do not open the file.

### 3b — Superhuman Docs (syntax from the extension page; not exercised on this machine)

```sql
LOAD superhuman_docs;   -- INSTALL superhuman_docs FROM community; in the local client if missing
-- CREATE SECRET name (TYPE superhuman_docs, TOKEN ...)  -- token via getenv, never a literal
CREATE SECRET superhuman_docs_token (TYPE superhuman_docs, TOKEN getenv('SUPERHUMAN_DOCS_TOKEN'));
-- ATTACH '<doc-id or Coda/Superhuman URL>' AS doc (TYPE superhuman_docs)
ATTACH '<doc-id>' AS doc (TYPE superhuman_docs);
FROM doc.main."Tasks" LIMIT 1;   -- document tables are DuckDB tables; INSERT/UPDATE/DELETE write back
```

Ask where the API token lives (a 0600 file) and export it on the shell line like the quack token.

## Step 3 — What is on it (the server's catalog, whole rows)

```bash
QUACK_TOKEN="$(cat ~/.duck/token)" duckdb :memory: -csv -c "
LOAD quack;
ATTACH 'quack:localhost:9494' AS dev (TYPE quack, TOKEN getenv('QUACK_TOKEN'));
FROM dev.query(\$\$
  SELECT database_name, schema_name, table_name, estimated_size, column_count
  FROM duckdb_tables() WHERE NOT internal ORDER BY 1, 2, 3
\$\$);
" 2>&1 | grep -v 'Loading resources'
```

Client-side `duckdb_tables()` shows **nothing** for a quack attach — always ask the server.
For each table of interest (start with the ones the task names; do not `DESCRIBE` all twenty):

```sql
FROM dev.query($$DESCRIBE <table_name>$$);
```

`estimated_size` is the row count for a summary; do not `count(*)` every table.

## Step 4 — Report

- **Door**: URI, port, which token file, read-write or read-only; the `whoami` row
- **Head**: the two lines from Step 1, verbatim, for every statement / artifact that follows
- **Tables**: name, column count, estimated rows — or "empty"
- Reminders: joins across dev tables go through `dev.query($$…$$)`; `SET`/`INSTALL`/`LOAD`
  are refused on dev; `/duckdb-skills:query` runs the work, `/duckdb-skills:crawl` lands pages.

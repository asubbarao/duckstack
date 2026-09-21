---
name: agent-log
description: >
  Log what you did as parquet, in one call (the dev MCP `agent_log` tool), so a human can read every agent's work in SQL.
  Use whenever you run a query or a program worth keeping, and whenever you dispatch subagents —
  they call this themselves, you do not collect their output. One call per artifact: the same
  token is stored as text and executed, so the result cannot be invented; a crash is a row, not a
  lost turn. `FILENAME_PATTERN '{uuid}'` makes n writers into one directory safe with no lock.
  Works the same for SQL, Python, .bat or any other language.
argument-hint: "<agent-name> [sql | code] [dir]"
allowed-tools: Bash, mcp__dev__agent_log, mcp__dev__query
---

# agent-log

One call. No setup, nothing to read first. A subagent can be handed this and get it right
without the dispatching agent checking up on it.

## The rule

**The same token is stored quoted and executed bare.** That is the whole point: you cannot write
a result you did not produce, because the result column *is* the execution. If you hand-write the
answer instead, the audit below catches it.

```
'<SQL>' AS query_was_ran,  (<SQL>) AS result          -- one token, twice
```

`'<X>'` when the replacement must be a quoted literal, bare `<X>` when it is an identifier or a
statement — the same convention as `'<DATEID-3>'` and `<TABLE:tablename>`.

## Primary: the `agent_log` MCP tool (the `dev` server, 9496)

For SQL, call the tool. The server binds `sql` once and uses it twice — stored as
`query_was_ran`, executed by `query()` — so the rule above holds with **nothing to escape**:
every argument is a bound value, quotes and newlines included.

| argument | required | what |
|---|---|---|
| `agent` | yes | your model name: `opus`, `terra`, `luna`, `sol`, … — nothing derives it |
| `type` | yes | the topic; becomes the partition `type=<type>/` |
| `sql` | yes | the query, verbatim; one row or many, its columns land typed |
| `notes` | no | markdown |
| `session_id` | no | your `CLAUDE_CODE_SESSION_ID` / `CODEX_THREAD_ID`; the server cannot read your env |

**Two ways to make the same call, to the same tool on the same server.** If your harness has
attached `dev` (`mcp__dev__agent_log`), call that. If it has not — a different agent system, a
client that dropped the server, a subagent with no MCP config — post the call over HTTP. Any agent
with a shell can; the quoted heredocs (`<<'SQL'`) take the text verbatim and `jq --arg` builds the
JSON, so **nothing is escaped**:

```bash
jq -n --arg agent '<AGENT>' --arg type '<type>' --arg session_id "${CODEX_THREAD_ID:-$CLAUDE_CODE_SESSION_ID}" \
  --arg sql "$(cat <<'SQL'
<SQL>
SQL
)" --arg notes "$(cat <<'MD'
<NOTES>
MD
)" '{jsonrpc:"2.0", id:1, method:"tools/call",
     params:{name:"agent_log", arguments:{$agent, $type, $session_id, $sql, $notes}}}' \
| curl -s http://localhost:9496/mcp -H 'Content-Type: application/json' \
       -H 'Accept: application/json, text/event-stream' -d @- | jq -c '.error // .result'
```

Verified 2026-09-21 with SQL and notes carrying `'`, `"`, `` ` ``, `$HOME` and `\` — all stored
verbatim, result correct.

Rows land in `~/.duck/agent_log/rows/type=<type>/<uuid>.parquet`. Read them back with the
`query` tool (or the same curl with `"name":"query", "arguments":{"sql": …}`) — it refuses
`read_parquet`, so go through the view:

```sql
SELECT agent, query_was_ran, markdown_notes, * EXCLUDE (agent, query_was_ran, markdown_notes)
FROM agent_log WHERE type = '<type>' ORDER BY row_id;
```

Invalid SQL returns the error to you and writes no row — fix it and call again. Verified
2026-09-21: 12 concurrent calls, 12 files, all results correct.

**The local form below is only for programs** (Python, bash — the sidecar has no shellfs) or for
reading files outside the sidecar's allowed directories.

## Programs: your own `duckdb :memory:`

### The prelude — every template starts with this, then one COPY

Paste it whole. It loads what the COPY needs, defines `agent_session()`, and creates `<DIR>` —
`COPY … PARTITION_BY` does **not** create a missing parent directory; without this line a fresh
directory fails with `Failed to create directory … No such file or directory`.

```sql
LOAD markdown; LOAD shellfs;
CREATE OR REPLACE MACRO agent_session() AS {
  'system': CASE
              WHEN nullif(getenv('CODEX_THREAD_ID'), '') IS NOT NULL THEN 'codex'
              WHEN nullif(getenv('CLAUDE_CODE_SESSION_ID'), '') IS NOT NULL THEN 'claude'
              ELSE 'unknown' END,
  'session_id': coalesce(nullif(getenv('CODEX_THREAD_ID'), ''),
                         nullif(getenv('CLAUDE_CODE_SESSION_ID'), ''))
};
-- COPY ... TO '| <cmd>' pipes the rows to the command's stdin; mkdir ignores them and just runs.
-- mkdir -p is a no-op when the directory exists, so running the prelude twice is harmless.
COPY (SELECT 1) TO '| mkdir -p <DIR>';
```

`getenv()` returns `''` for an unset variable, not NULL — that is why the `nullif` calls are there.

### SQL, scalar answer

```sql
COPY (SELECT uuidv7() AS row_id, '<type>' AS type,
             '<AGENT>' AS agent, agent_session().system AS agent_system,
             agent_session().session_id AS session_id,
             '<SQL>' AS query_was_ran, (<SQL>)::VARCHAR AS result,
             '<NOTES>' AS markdown_notes, md_valid('<NOTES>') AS notes_ok, now() AS ts)
TO '<DIR>' (FORMAT parquet, PARTITION_BY (type), OVERWRITE_OR_IGNORE true,
            FILENAME_PATTERN '{uuid}');
```

### SQL, many rows

Same statement; the result arrives as typed columns instead of one string, so it stays queryable.

```sql
COPY (SELECT uuidv7() AS row_id, '<type>' AS type, '<AGENT>' AS agent,
             '<SQL>' AS query_was_ran, '<NOTES>' AS markdown_notes, now() AS ts, r.*
      FROM (<SQL>) r)
TO '<DIR>' (FORMAT parquet, PARTITION_BY (type), OVERWRITE_OR_IGNORE true,
            FILENAME_PATTERN '{uuid}');
```

Readers of a directory holding both shapes need `union_by_name := true`.

### Any other language

The code becomes a file first. **Nothing is escaped** — that is why this works where inlining a
program into SQL does not.

```sql
-- 1. write the artifact. QUOTE '' keeps it verbatim.
COPY (SELECT '<CODE>') TO '<DIR>/<NAME>.py' (FORMAT csv, HEADER false, QUOTE '');

-- 2. store the same token and run it. `2>&1; true` is required, see below.
COPY (SELECT uuidv7() AS row_id, 'programs' AS type, '<AGENT>' AS agent,
             'python3 <NAME>.py' AS ran, '<CODE>' AS code,
             (SELECT string_agg(line, chr(10)) FROM read_csv(
                'python3 <DIR>/<NAME>.py 2>&1; true |',
                header := false, columns := {'line':'VARCHAR'}, ignore_errors := true)
             ) AS result,
             '<NOTES>' AS markdown_notes, now() AS ts)
TO '<DIR>' (FORMAT parquet, PARTITION_BY (type), OVERWRITE_OR_IGNORE true,
            FILENAME_PATTERN '{uuid}');
```

Swap `python3` for `bash`, `cmd /d /s /c`, `node` — the row shape does not change.

## Four things that are load-bearing

- **`FILENAME_PATTERN '{uuid}'`** is the concurrency guarantee. Verified: three agents wrote the
  same partition directory simultaneously, got three distinct files, zero errors, all readable
  together. Nothing is read-modify-written, so there is nothing to lock and no queue.
- **`2>&1; true`** — without it, shellfs aborts the whole statement when the child exits non-zero
  (`Pipe process exited abnormally code=1`) and one bad program takes the write down. With it a
  crash is a row carrying its traceback, so running the COPY always beats not running it. Query
  the parquet for the failures later.
- **`try()` cannot rescue a broken scalar subquery** — `TRY can not be used in combination with a
  scalar subquery`. For SQL, a broken query means no row at all; that is honest, and the missing
  row is itself the signal.
- **`<AGENT>` is yours to supply** (`opus`, `terra`, `luna`, …). Nothing derives it. `agent_session()`
  supplies only the system and session id.

## agent_session()

It is in the prelude, and it must run in your **own** process: `getenv()` reads the environment
of whichever DuckDB evaluates it. Your `:memory:` client has your session's ids. The dev quack on
9494 and the MCP sidecar are launchd processes with their own environments — verified 2026-09-21,
the quack returns empty for both ids and the sidecar has `getenv` disabled outright by
`enable_external_access = false`.

Codex is checked first deliberately: a Codex worker launched by Claude **inherits**
`CLAUDE_CODE_SESSION_ID`, so the Claude id would otherwise mislabel the worker. Verified both ways.

One id per session, so every row a session writes shares it — group by `session_id` to see one
agent's whole run.

## Reading it back

```sql
SELECT agent, agent_system, query_was_ran, result, markdown_notes
FROM read_parquet('<DIR>/**/*.parquet', hive_partitioning := true, union_by_name := true);
```

`markdown_notes` is markdown: `md_valid` checks it at write time, and `md_extract_sections` /
`md_to_text` / `parse_markdown_to_duck_blocks` make everyone's notes queryable as structure rather
than text.

## Auditing — catching an agent that invented a result

Because every row carries the query that produced it, re-run it and compare. `query_was_ran` is a
column and a table function binds literals, so build the statement per row and post it to your own
route (`/duckstack:self-dispatch` Form 1). Verified: two honest agents matched, one that
hand-wrote `99` for `SELECT 6 * 7` was caught.

```sql
CREATE OR REPLACE ROUTE run POST '/run' AS SELECT rows.* FROM query($q) rows;
SELECT listen_url FROM quackapi_serve(19584, host := '127.0.0.1');
-- array_agg(http_post_form(...)) is the barrier; compare the answer to the stored result
SELECT status FROM quackapi_stop(19584);
```

## Dispatching subagents

Give the worker its `<AGENT>` name and a `type`, and tell it to call `agent_log` (or the local
form, with `<DIR>`) — nothing else. It writes its own rows; you do
not collect them, and a worker that fails writes a row saying so. Then read the directory.

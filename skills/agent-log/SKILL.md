---
name: agent-log
description: >
  Log what you did as parquet, in one call (a COPY through the dev MCP `sql` tool), so a human can read every agent's work in SQL.
  Use whenever you run a query or a program worth keeping, and whenever you dispatch subagents —
  they call this themselves, you do not collect their output. One call per artifact: the same
  token is stored as text and executed, so the result cannot be invented; a crash is a row, not a
  lost turn. `FILENAME_PATTERN '{uuid}'` makes n writers into one directory safe with no lock.
  Works the same for SQL, Python, .bat or any other language.
argument-hint: "<agent-name> [sql | code] [dir]"
allowed-tools: Bash, mcp__dev__sql
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

## Primary: one `sql` call on the `dev` MCP

The `dev` MCP's `sql` tool runs any SQL on dev, `COPY` included. Dollar-quote the query and the
notes (`$query$…$query$`, `$notes$…$notes$`) and **nothing is escaped** — quotes, newlines and
`$HOME` go through as written. The same `$query$…$query$` token is stored and executed.

```sql
COPY (SELECT uuidv7() AS row_id, '<type>' AS type, '<AGENT>' AS agent, '<SESSION_ID>' AS session_id,
             '<AGENT>-<SESSION_ID>' AS agent_signature,
             $query$<SQL>$query$ AS query_was_ran, r.*,
             $notes$<NOTES>$notes$ AS markdown_notes, now() AS ts
      FROM query($query$<SQL>$query$) r)
TO '/Users/aloksubbarao/.duck/agent_log/signed'
   (FORMAT parquet, PARTITION_BY (type, agent_signature), OVERWRITE_OR_IGNORE true, FILENAME_PATTERN '{uuid}');
```

- `<AGENT>` is `<system>-<model>-<version>`, plus `-<thinking level>` when you know it:
  `claude-opus-5.5`, `claude-sonnet-5`, `codex-terra-5.6-high`, `codex-luna-5.6-medium`.
  Nothing derives it — a bare `terra` does not say which Terra or how hard it thought.
- `agent_signature` is `<AGENT>-<SESSION_ID>`, and it is the second partition. `type` comes
  first because it is what a reader filters on; the signature partition is there for safety —
  each writer owns its own directory, so with `OVERWRITE_OR_IGNORE` and
  `FILENAME_PATTERN '{uuid}'` no writer can touch another's files.
- `markdown_notes` is always present: what you'd tell the reader about this row. NULL only when
  there is genuinely nothing to add.
- `<SESSION_ID>` is your `CLAUDE_CODE_SESSION_ID` or `CODEX_THREAD_ID`. Pass it as a literal —
  `getenv()` on dev reads the server's environment, not yours.
- `query()` takes exactly one SELECT; a query that fails returns its error and writes nothing.
- `signed/` is the `(type, agent_signature)` layout. The older `rows/` beside it is `(type)`
  only; never mix the two depths in one directory — `read_parquet('**/*.parquet',
  hive_partitioning := true)` fails with "Hive partition mismatch … key agent_signature not found".

No `dev` MCP attached? Same statement, same door, over HTTP:
`curl -s -X POST localhost:9495/sql --data-urlencode sql@statement.sql`.

Read it back with the same tool:

```sql
SELECT agent, query_was_ran, markdown_notes, * EXCLUDE (agent, query_was_ran, markdown_notes)
FROM read_parquet('/Users/aloksubbarao/.duck/agent_log/signed/**/*.parquet',
                  hive_partitioning := true, union_by_name := true)
WHERE type = '<type>' ORDER BY row_id;
```

Verified 2026-09-22 through the `dev` MCP `sql` tool: row written and read back, `it's` and
`$HOME` stored verbatim.

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
             '<AGENT>-' || coalesce(agent_session().session_id, 'no-session') AS agent_signature,
             '<SQL>' AS query_was_ran, (<SQL>)::VARCHAR AS result,
             '<NOTES>' AS markdown_notes, md_valid('<NOTES>') AS notes_ok, now() AS ts)
TO '<DIR>' (FORMAT parquet, PARTITION_BY (type, agent_signature), OVERWRITE_OR_IGNORE true,
            FILENAME_PATTERN '{uuid}');
```

### SQL, many rows

Same statement; the result arrives as typed columns instead of one string, so it stays queryable.

```sql
COPY (SELECT uuidv7() AS row_id, '<type>' AS type, '<AGENT>' AS agent,
             '<AGENT>-' || coalesce(agent_session().session_id, 'no-session') AS agent_signature,
             '<SQL>' AS query_was_ran, '<NOTES>' AS markdown_notes, now() AS ts, r.*
      FROM (<SQL>) r)
TO '<DIR>' (FORMAT parquet, PARTITION_BY (type, agent_signature), OVERWRITE_OR_IGNORE true,
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
             '<AGENT>-' || coalesce(agent_session().session_id, 'no-session') AS agent_signature,
             'python3 <NAME>.py' AS ran, '<CODE>' AS code,
             (SELECT string_agg(line, chr(10)) FROM read_csv(
                'python3 <DIR>/<NAME>.py 2>&1; true |',
                header := false, columns := {'line':'VARCHAR'}, ignore_errors := true)
             ) AS result,
             '<NOTES>' AS markdown_notes, now() AS ts)
TO '<DIR>' (FORMAT parquet, PARTITION_BY (type, agent_signature), OVERWRITE_OR_IGNORE true,
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
- **`<AGENT>` is yours to supply** (`claude-opus-5.5`, `codex-terra-5.6-high`, …). Nothing derives
  it. `agent_session()` supplies only the system and session id.

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
route (`/duckstack:self-dispatch` — on dev, rows → statements → array_agg of the posts to `/sql` → UNNEST). Verified: two honest agents matched, one that
hand-wrote `99` for `SELECT 6 * 7` was caught.

```sql
CREATE OR REPLACE ROUTE run POST '/run' AS SELECT rows.* FROM query($q) rows;
SELECT listen_url FROM quackapi_serve(19584, host := '127.0.0.1');
-- array_agg(http_post_form(...)) is the barrier; compare the answer to the stored result
SELECT status FROM quackapi_stop(19584);
```

## Dispatching subagents

Give the worker its full `<AGENT>` label (system-model-version-thinking), its session id and a `type`, and tell it to run the COPY above
through the `dev` MCP `sql` tool (or the local form, with `<DIR>`, for programs) — nothing else. It writes its own rows; you do
not collect them, and a worker that fails writes a row saying so. Then read the directory.

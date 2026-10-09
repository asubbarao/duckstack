---
name: agent-log
description: >
  Log what you did as parquet, in one call (a COPY through the dev MCP `execute` tool), so a human can read every agent's work in SQL.
  Use whenever you run a query or a program worth keeping, and whenever you dispatch subagents —
  they call this themselves, you do not collect their output. One call per artifact: the same
  token is stored as text and executed, so the result cannot be invented; a crash is a row, not a
  lost turn. `FILENAME_PATTERN '{uuid}'` makes n writers into one directory safe with no lock.
  Works the same for SQL, Python, .bat or any other language.
argument-hint: "<agent-name> [sql | code] [dir]"
allowed-tools: mcp__dev__query, mcp__dev__execute
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

## Primary: one `execute` call on the `dev` MCP

The `dev` MCP's `execute` tool runs any statement on dev, `COPY` included. Dollar-quote the query and the
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
`curl -s -X POST localhost:9495/sql -H 'content-type: application/json' \
  -d "$(jq -n --rawfile s statement.sql '{sql:$s}')"`.

Read it back with the same tool:

```sql
SELECT agent, query_was_ran, markdown_notes, * EXCLUDE (agent, query_was_ran, markdown_notes)
FROM read_parquet('/Users/aloksubbarao/.duck/agent_log/signed/**/*.parquet',
                  hive_partitioning := true, union_by_name := true)
WHERE type = '<type>' ORDER BY row_id;
```

Verified 2026-09-22 through the `dev` MCP: row written and read back, `it's` and
`$HOME` stored verbatim.

## Programs: your own `duckdb :memory:`

### The prelude — every template starts with this, then one COPY

Paste it whole. It loads what the COPY needs and creates `<DIR>` — `COPY … PARTITION_BY` does
**not** create a missing parent directory; without this line a fresh directory fails with
`Failed to create directory … No such file or directory`.

```sql
LOAD markdown; LOAD shellfs;
FROM read_text('mkdir -p <DIR> |');
```

`<SESSION>` below is your session id as a literal: `$CODEX_THREAD_ID` for Codex,
`$CLAUDE_CODE_SESSION_ID` for Claude (check Codex first: a Codex worker launched by Claude inherits
the Claude id). `getenv()` would read the environment of whichever DuckDB evaluates it, so on dev it
returns the server's, not yours.

### SQL, scalar answer

```sql
COPY (SELECT uuidv7() AS row_id, '<type>' AS type,
             '<AGENT>' AS agent, '<SESSION>' AS session_id,
             '<AGENT>-<SESSION>' AS agent_signature,
             '<SQL>' AS query_was_ran, (<SQL>)::VARCHAR AS result,
             '<NOTES>' AS markdown_notes, md_valid('<NOTES>') AS notes_ok, now() AS ts)
TO '<DIR>' (FORMAT parquet, PARTITION_BY (type, agent_signature), OVERWRITE_OR_IGNORE true,
            FILENAME_PATTERN '{uuid}');
```

### SQL, many rows

Same statement; the result arrives as typed columns instead of one string, so it stays queryable.

```sql
COPY (SELECT uuidv7() AS row_id, '<type>' AS type, '<AGENT>' AS agent,
             '<SESSION>' AS session_id, '<AGENT>-<SESSION>' AS agent_signature,
             '<SQL>' AS query_was_ran, '<NOTES>' AS markdown_notes, now() AS ts, r.*
      FROM (<SQL>) r)
TO '<DIR>' (FORMAT parquet, PARTITION_BY (type, agent_signature), OVERWRITE_OR_IGNORE true,
            FILENAME_PATTERN '{uuid}');
```

Readers of a directory holding both shapes need `union_by_name := true`.

## Four things that are load-bearing

- **`FILENAME_PATTERN '{uuid}'`** is the concurrency guarantee. Verified: three agents wrote the
  same partition directory simultaneously, got three distinct files, zero errors, all readable
  together. Nothing is read-modify-written, so there is nothing to lock and no queue.
- **`try()` cannot rescue a broken scalar subquery** — `TRY can not be used in combination with a
  scalar subquery`. For SQL, a broken query means no row at all; that is honest, and the missing
  row is itself the signal.
- **`<AGENT>` and `<SESSION>` are yours to supply** (`claude-opus-5.5`, `codex-terra-5.6-high`, …).
  Nothing derives them. One id per session, so group by `session_id` to see one agent's whole run.

## Reading it back

```sql
SELECT agent, agent_system, query_was_ran, result, markdown_notes
FROM read_parquet('<DIR>/**/*.parquet', hive_partitioning := true, union_by_name := true);
```

`markdown_notes` is markdown: `md_valid` checks it at write time, and `md_extract_sections` /
`md_to_text` / `parse_markdown_to_duck_blocks` make everyone's notes queryable as structure rather
than text.

## Auditing — catching an agent that invented a result

Because every row carries the query that produced it, re-run it on dev and compare
(`/duckstack:self-dispatch`). Verified: two honest agents matched, one that hand-wrote `99` for
`SELECT 6 * 7` was caught.

```sql
WITH logged AS (
    SELECT agent_signature, query_was_ran, result
    FROM read_parquet('<DIR>/**/*.parquet', hive_partitioning := true, union_by_name := true)
    WHERE query_was_ran IS NOT NULL
), rerun AS (
    SELECT *, from_json(http_post('http://127.0.0.1:9495/sql', MAP {'Content-Type': 'application/json'},
                                  json_object('sql', 'SELECT (' || query_was_ran || ')::VARCHAR AS result')),
                        '{"status": "INTEGER", "body": "VARCHAR"}') AS receipt
    FROM logged
)
SELECT agent_signature, query_was_ran, result AS logged_result,
       from_json(receipt.body, '[{"result": "VARCHAR"}]')[1].result AS rerun_result
FROM rerun WHERE rerun_result IS DISTINCT FROM result
```

## Dispatching subagents

Give the worker its full `<AGENT>` label (system-model-version-thinking), its session id and a `type`, and tell it to run the COPY above
through the `dev` MCP `execute` tool (or the local JSON POST, with `<DIR>`, for programs) — nothing else. It writes its own rows; you do
not collect them, and a worker that fails writes a row saying so. Then read the directory.

## Signed notes, decisions, and artifacts

Use the same `agent_signature` partition for substantive notes and artifacts, not only
query results. Preserve observations, interpretations, proposals, rejected options, and
open questions with their evidence state and source references. A signature identifies
who recorded the item; it does not make an authored claim true.

For an existing note or artifact, execute a SELECT that reads its actual contents and
hash, store that exact SELECT in `query_was_ran`, and COPY the result with the usual
`agent`, `session_id`, `agent_signature`, `markdown_notes`, and `ts` columns. For example:

```sql
SELECT filename AS artifact_path, sha256(content) AS artifact_sha256,
       content AS artifact_content, 'authored_proposal' AS evidence_state
FROM read_text('/absolute/path/design.md')
```

The outer COPY stores and executes that SELECT using the primary template above.
The result proves which artifact bytes were recorded, not the truth of every sentence.
Use structured note rows when practical: `note_id`, `evidence_state`,
`source_refs`, `artifact_path`, and `markdown_notes`. Keep observed facts separate
from inferences and proposed decisions; label synthetic examples explicitly. Store
superseding notes with a reference to the earlier note rather than rewriting the bank.
Read the signed rows back and verify their source references, contents, and hashes.

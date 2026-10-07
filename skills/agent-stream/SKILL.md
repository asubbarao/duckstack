---
name: agent-stream
description: Find recent or relevant agent conversations, then drill into complete messages and tool activity.
---

# Agent stream

The standalone [agent_data query bank](references/agent_data_query_bank.sql)
reads `read_conversations()` directly for recent Luna usage, message/tool links,
native parent edges, and evidence-labelled CLI launch reconstruction. Its twelve
queries were exercised on 2026-10-01: three native probes and five CLI Lunas
linked to the same parent. Inputs are literals/CTEs, with timestamp and flag
arrays retained alongside summaries. The current case adapter is Codex;
Claude/Desktop sources and positive message-UUID chains still need validation.

## Subagent relationship evidence

Use the raw `agent.conversations` reader union when inspecting relationships,
not `agent.stream`. Check the loaded reader version: on 2026-09-30 the main
process's `ca2c0b8` classified native Codex children as `is_agent = false`, while
the existing repaired reader's `333812b` correctly exposed `parent_session_id`,
`agent_path`, and `thread_source = 'subagent'` for the same live files.

`is_agent` is provider-specific classification, not a universal parent link.
Native Codex child metadata records the parent thread; a separately launched
`codex exec` session may have `thread_source = 'exec'` and no parent. Preserve
launching tool calls and child metadata so callers can reconstruct such links.
Do not classify every CLI session as a subagent or infer a parent solely from a
shared project directory. Explicit dispatch records should carry both source
and session IDs; reconstructed links should state their evidence separately.

Claude child transcripts can carry their parent's `session_id`; distinguish
siblings by transcript `file_path`/`file_name` and child identity, not session ID
alone. `parent_uuid` links messages and is not a conversation parent ID.

The current reader loads history before SQL filters apply. When checking known
Codex transcripts, use `read_conversations(path := '<exact rollout file>',
source := 'codex')` through the repaired reader. This completed in two seconds
for a root, three native children and one CLI session; a full-history query
exceeded the MCP transport wait and completed later. A transport timeout does
not mean the query stopped. Check state before replaying writes.

`agent.conversations` is the complete `read_conversations()` base view on dev. It
includes raw events, metadata, identities, usage, tools, and diagnostics. Select
only the columns needed for a query; NULL means the source or reader has no value.
`agent.stream` is the five-minute normalized table with `user`, `agent`,
`tool_call`, `tool_result`, `system`, and `other` rows. Full text stays there.

For a quick catch-up, use `agent.stream_conversation`: one row per system/session,
all active days, last timestamp, and ten recent user/agent messages in time order.
Every message struct has `content_head`, `content_tail`, and `content_length`.
Text at most 200 characters is entirely in `content_head` and has a NULL tail;
longer text has its first and last 100 characters. The IDs locate full text.

```sql
SELECT system, session_id, project_path, days, last_ts, message_count, preview
FROM agent.stream_conversation
WHERE last_ts >= current_timestamp - INTERVAL '12 hours'
ORDER BY last_ts DESC
LIMIT 10;
```

Use the `stream_recent` MCP tool with `hours: 12` for the latest compact rows,
or `stream_session` with a session ID for its compact transcript.

## Search: `agent.stream_hour`

Search reads `agent.stream_hour`, one row per `(system, session_id, UTC hour)`
(~1,500 rows for ~300k text-bearing messages on 2026-10-04). Each row has
`hour_id`, ordered `ids`, `condensed_items` (speaker-prefixed, whole text if
<= 200 chars, else left 100 + ` ... ` + right 100), `search_text` (items joined
by newline), `role_counts` (MAP), `message_count`, `source_chars`, first/last ts
and `project_path`. Speakers are `human`/`agent`/`harness`/`tool` for user rows
(from `agent.user_text`) and the message role otherwise. Excluded: rows with no
text (about 60% of `agent.stream`, e.g. attachments, token counts, reasoning
stubs), typed human pastes over 10,000 chars, and non-human rows under 50 chars.

- `stream_search` (`server/agent_stream_search.sql`): native FTS BM25
  (`fts_agent_stream_hour.match_bm25`, porter stems, english stopwords). Five
  hours, each with up to five matching items `{hits, id, item}`. Pass the query
  as a literal: a column argument to `match_bm25` turns into a correlated scan
  that ran for over two minutes, while a literal takes about 0.1 s.
- `stream_semantic` (`server/agent_stream_semantic.sql`): cosine over
  `agent.stream_hour_vector` (quackformers 384-d embedding of the first ~2,000
  chars of the hour's human/agent items; a tool-only hour uses its search text).
  An exact scan with no HNSW index: about 40 ms at 1.5k vectors.
- Neither returns full text. Fetch a row with `stream_message(id)`.

`server/agent_stream_hour.sql` + `agent_stream_hour_index.sql` run as one cron
job every five minutes (`agent_stream_schedule.sql`). An hour is rebuilt only
when its fingerprint (message count, last ts, chars) changes. That covers the open
hour, late rows and deleted hours. The FTS index is rebuilt (~4-7 s, transactional:
searches keep the old index meanwhile) only when the table fingerprint differs
from the last successful build in `agent.stream_hour_fts_build`. At most 128
embeddings per tick, newest first (~2.5-5 s warm). The first `embed()` after a
restart loads the model, adding about 2.5-3.5 GB to dev's RSS while it stays loaded.
QuackAPI `/sql` re-serializes statements and drops PRAGMA named arguments
(`overwrite = 1`), so the FTS PRAGMA is dispatched as a literal inside
`quack_query`.

Complete text is an explicit ID lookup. Call `stream_message` with an exact `id`
from a compact result. Direct SQL should use the same keyed shape:

```sql
SELECT id, system, session_id, ts, message_role, tool_data, message_content, content_length
FROM agent.stream
WHERE id = 'EXACT_ID'
LIMIT 3;
```

Use `stream_tools` with `session_id` and `hours` for a shorter tool drill-down.
It groups by hour, tool name, and command program, reports calls and matched
outputs, and retains output-only rows with a NULL tool name. Failure counts
use explicit status only; a completed transport does not prove the command
succeeded. Use `stream_message` for complete arguments and outputs.

## Multi-term tool-history search

When investigating an extension or workflow from tool-call text, use a token
array and `array_intersect`, rather than a chain of text predicates. Keep the
match terms in the query, project them directly with each stream row, and set
the threshold deliberately: `>= 1` is a broad discovery pass; raise it only
when the task needs co-occurrence. This captures calls that mention any of the
related tools without requiring a brittle Boolean text expression.

```sql
WITH candidates AS (
    SELECT
        ['webbed', 'crawler', 'quickjs', 'jsonata', 'tera', 'shellfs'] AS match_arr,
        ts,
        system,
        session_id,
        tool_data ->> 'name' AS tool_name,
        CASE WHEN content_length <= 200 THEN message_content ELSE left(message_content, 100) END AS content_head,
        CASE WHEN content_length > 200 THEN right(message_content, 100) END AS content_tail,
        content_length,
        string_split(lower(coalesce(message_content, '')), ' ') AS tokens
    FROM agent.stream
    WHERE message_role = 'tool_call'
)
SELECT
    ts,
    system,
    session_id,
    tool_name,
    array_intersect(tokens, match_arr) AS matched_terms,
    content_head,
    content_tail,
    content_length
FROM candidates
WHERE len(array_intersect(tokens, match_arr)) >= 1
ORDER BY ts DESC
LIMIT 20;
```

For exact punctuation-sensitive terms, normalize the text before splitting;
do not fall back to Boolean `OR` text matching.

`agent.stream_day` is another grain, but includes all roles in its samples.
The complete base view is installed by `server/agent_base.sql`; the five-minute
job runs `server/agent_stream_incremental.sql` through
`server/agent_stream_schedule.sql`. It rereads eight hours at the worker,
replaces the recent seven-hour overlap, and keeps older stream history. A newly
arriving record with an older timestamp needs a wider reconciliation.
`agent.reader_build` identifies the current temporary reader artifact. The main
signed DuckDB owns the stream, the hour search table, its FTS index and vectors.

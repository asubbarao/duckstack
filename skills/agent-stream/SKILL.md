---
name: agent-stream
description: Find recent or relevant agent conversations, then drill into complete messages and tool activity.
---

# Agent stream

`agent.conversations` is the complete `read_conversations()` base view on dev. It
includes raw events, metadata, identities, usage, tools, and diagnostics. Select
only the columns needed for a query; NULL means the source or reader has no value.
`agent.stream` is the five-minute normalized table with `user`, `agent`,
`tool_call`, `tool_result`, `system`, and `other` rows. Full text stays there.

For a quick catch-up, use `agent.stream_conversation`: one row per system/session,
all active days, last timestamp, and ten recent user/agent messages in time order.
The preview trims each message to 150 characters; the IDs locate full text.

```sql
SELECT system, session_id, project_path, days, last_ts, message_count, preview
FROM agent.stream_conversation
WHERE last_ts >= current_timestamp - INTERVAL '12 hours'
ORDER BY last_ts DESC
LIMIT 10;
```

Use the `stream_recent` MCP tool with `hours: 12` for this preview. Search with
the `stream_search` tool or the saved `agent_stream_search.sql`.
BM25 covers non-NULL message content, including tool calls and outputs. Search
returns compact user/agent previews; inspect a selected session through the
base or normalized table:

```sql
SELECT ts, message_role, message_content, uuid, id, turn_id
FROM agent.stream
WHERE session_id = 'YOUR_SESSION_ID' AND message_role IN ('user', 'agent')
ORDER BY ts, id;

SELECT ts, message_role, tool_data, message_content, status, id
FROM agent.stream
WHERE session_id = 'YOUR_SESSION_ID' AND message_role IN ('tool_call', 'tool_result')
ORDER BY ts, id;
```

Use `stream_tools` with `session_id` and `hours` for a shorter tool drill-down.
It groups by hour, tool name, and command program, reports calls and matched
outputs, and retains output-only rows with a NULL tool name. Failure counts
use explicit status only; a completed transport does not prove the command
succeeded. Query `agent.stream` for complete arguments and outputs.

`agent.stream_day` is another grain, but includes all roles in its samples.
The complete base view is installed by `server/agent_base.sql`; the five-minute
job runs `server/agent_stream_incremental.sql` through
`server/agent_stream_schedule.sql`. It rereads eight hours at the worker,
replaces the recent seven-hour overlap, and keeps older stream history. A newly
arriving record with an older timestamp needs a wider reconciliation.
`agent.reader_build` identifies
the current temporary reader artifact. The main signed DuckDB owns the stream,
BM25 tables, and vectors.
